module rwa::rwa {
    use sui::object::{Self, UID, ID};
    use sui::object_bag::{Self, ObjectBag};
    use sui::transfer;
    use sui::package;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use std::vector;
    use sui::vec_set::{Self, VecSet};
    use sui::coin::{Self, Coin};
    use rwa::utils;
    use rwa::ratio::{Self, Ratio};
    use sui::event;
    use sui::table::{Self, Table};

    // 版本
    const VERSION: u64 = 0;
    // 单价缩放比例（单价ratio的分母部分，当分子为1000000时，表示1：1）
    const PRICE_SCALING: u64 = 1000000;

    // 错误码
    const EVersionNotMatched: u64 = 100000;                           // 版本不一致
    const ENotRWAAdmin: u64 = 100001;                                 // 非RWA ADMIN
    const ENotProjectAdmin: u64 = 10002;                              // 非RWA项目ADMIN
    const ENotProjectFinancier: u64 = 10003;                          // 非RWA项目财务
    const ENotRwaWhitelist: u64 = 10004;                              // 非RWA白名单，不允许发布RWA项目
    const EAlreadyRwaWhitelist: u64 = 10005;                          // 已经是RWA白名单
    const EProjectKeyExists: u64 = 10006;                             // project_key重复
    const ERwaProjectNotFound: u64 = 10007;                           // RWA project项目未找到
    const ECoinsEmpty: u64 = 10008;                                   // 输入vector<Coin>为空
    const EBuyNumZero: u64 = 10009;                                   // 购买数量为0
    const ERwaPaused: u64 = 10010;                                    // RWA暂停状态
    const EDividendRecordExists: u64 = 10011;                         // 分红批次存在
    const EDividendRecordNotFound: u64 = 10012;                       // 分红批次记录不存在
    const EDividendAmountZero: u64 = 10013;                           // 分红金额不能为0
    const ERwaTokenTotalSupplyZero: u64 = 10014;                      // 发行量快照为0，无需分红
    const EUsersAndParticipatingDividendsNotMatch: u64 = 10015;       // 参与分红的账户地址与拥有代币不匹配
    const EParticipatingUserEmpty: u64 = 10016;                       // 参与分红的账户地址为空
    const ERemainingDividendRwaTotalZero: u64 = 10017;                // 分红追加账户参与分红的rwa token超限
    const EParticipatingDividendsOverlimit: u64 = 10018;              // 参与分红的金额超限
    const EInsufficientDividendFundsReserve: u64 = 10019;             // 剩余可用分红的金额不足
    const EDuplicateDividendAccount: u64 = 10020;                     // 在同一分红批次中，参与分红的账户不允许重复

    struct RWA has drop {}

    struct RwaConfig has key {
        id: UID,
        // 超级管理员
        admin: address,
        // 启用/停止
        paused: bool,
        // 管理员白名单，用于限制是否允许发行项目的账户地址
        whitelist: VecSet<address>,
        // RWA项目
        projects: ObjectBag,
        // 版本
        version: u64
    }

    // RWA项目
    struct RwaProject<phantom X/*rwa project代币*/, phantom Y/*稳定币*/> has key, store {
        id: UID,
        // 项目编号（ObjectBag的KEY）
        project_key: vector<u8>,
        // 项目管理员
        admin: address,
        // 财务
        financier: address,
        // RWA价格
        price: Ratio,
        // RWA代币发行总量
        rwa_token_total_supply: u64,
        // RWA代币剩余量
        rwa_token_reserve: Balance<X>,
        // 用户购买RWA代币收入总量
        total_revenue: u64,
        // 用户购买RWA代币收入剩余量（因为存在提现/分红等行为，该量总量不等于total_revenue，并且财务也可能充钱进去）
        revenue_reserve: Balance<Y>,
        // 分红记录
        dividend_records: ObjectBag        
    }
    struct RwaProjectInfo<phantom X, phantom Y> has copy, drop {
        project_id: ID,
        project_key: vector<u8>,
        admin: address,
        financier: address,
        price: u64,
        rwa_token_total_supply: u64,
        rwa_token_reserve: u64,
        total_revenue: u64,
        revenue_reserve: u64
    }

    // 分红批次
    struct DividendBatchRecord<phantom Y> has key, store {
        id: UID,
        // rwa project key
        project_key: vector<u8>,
        // 分红标识，只需要保证在一个rwa project下面唯一即可
        record_key: vector<u8>,
        // 当前rwa token发行量（快照）
        rwa_token_total_supply: u64,
        // 分红剩余量+总分红金额
        dividend_funds_reserve: Balance<Y>,
        dividend_funds: u64,
        // 分红地址信息是多次提交的，防止提交涉及分红的token量与当前总快照不一致导致发行方短款
        already_dividend_rwa_total: u64,
        // 分红列表
        dividend_list: Table<address/*分红账户地址*/, u64/*rwa token拥有量*/>
    }

    // 事件
    struct RwaAdminChangedEvent has copy, drop {
        old_admin: address,
        new_admin: address
    }
    struct RwaPausedChangedEvent has copy, drop {
        paused: bool
    }
    struct RwaWhitelistChangedEvent has copy, drop {
        user: address,
        operate: vector<u8>
    }
    struct RwaProjectPublishEvent<phantom X, phantom Y> has copy, drop {
        project_id: ID,
        project_key: vector<u8>,
        admin: address,
        financier: address,
        price: u64,
        rwa_token_total_supply: u64,
        rwa_token_reserve: u64,
        total_revenue: u64,
        revenue_reserve: u64
    }
    struct RwaProjectAdminChangedEvent<phantom X, phantom Y> has copy, drop {
        old_admin: address,
        new_admin: address,
        project_id: ID,
        project_key: vector<u8>
    }
    struct RwaProjectFinancierChangedEvent<phantom X, phantom Y> has copy, drop {
        old_financier: address,
        new_financier: address,
        project_id: ID,
        project_key: vector<u8>
    }
    struct RwaProjectPriceChangedEvent<phantom X, phantom Y> has copy, drop {
        old_price: u64,
        new_price: u64,
        project_id: ID,
        project_key: vector<u8>
    }
    struct RwaProjectTokenIncreaseEvent<phantom X, phantom Y> has copy, drop {
        increase_supply: u64,
        project_id: ID,
        project_key: vector<u8>
    }
    struct RwaProjectTokenBuyEvent<phantom X, phantom Y> has copy, drop {
        user: address,
        price: u64,
        spend_amount: u64,
        buy_num: u64,
        project_id: ID,
        project_key: vector<u8>
    }
    struct RwaProjectDividendBatchRecordSubmitEvent<phantom X, phantom Y> has copy, drop {
        project_id: ID,
        project_key: vector<u8>,
        record_id: ID,
        record_key: vector<u8>,
        rwa_token_total_supply: u64,
        dividend_funds: u64
    }
    struct RwaProjectUserDividendIncomeEvent<phantom X, phantom Y> has copy, drop {
        project_id: ID,
        project_key: vector<u8>,
        record_id: ID,
        record_key: vector<u8>,
        user: address,
        dividend_income: u64
    }

    fun init(otw: RWA, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);

        let sender = tx_context::sender(ctx);
        transfer::share_object(RwaConfig {  
            id: object::new(ctx),
            admin: sender,
            paused: false,
            whitelist: vec_set::singleton(sender),
            projects: object_bag::new(ctx),
            version: VERSION
        });
    }

    // 转让管理权
    public entry fun set_rwa_admin(config: &mut RwaConfig, new_admin: address, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);

        let old_admin = config.admin;
        config.admin = new_admin;
        event::emit(RwaAdminChangedEvent { old_admin, new_admin });
    }

    // 启用或者关闭
    public entry fun set_rwa_paused(config: &mut RwaConfig, paused: bool, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        config.paused = paused;
        event::emit(RwaPausedChangedEvent { paused });
    }

    // 添加白名单
    public entry fun add_rwa_whitelist(config: &mut RwaConfig, user: address, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        // 白名单已经存在
        assert!(!vec_set::contains(&config.whitelist, &user), EAlreadyRwaWhitelist);
        vec_set::insert(&mut config.whitelist, user);
        event::emit(RwaWhitelistChangedEvent { user, operate: b"add" })
    }

    // 移除白名单
    public entry fun remove_rwa_whitelist(config: &mut RwaConfig, user: address, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        // 白名单不存在
        assert!(vec_set::contains(&config.whitelist, &user), ENotRwaWhitelist);
        vec_set::remove(&mut config.whitelist, &user);
        event::emit(RwaWhitelistChangedEvent { user, operate: b"remove" })
    }

    // 发布rwa project
    public entry fun publish_rwa_project<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, price: u64, x_tokens: vector<Coin<X>>, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);

        let price_ratio = ratio::ratio(price, PRICE_SCALING);

        let sender = tx_context::sender(ctx);
        // 非白名单不允许发布RWA项目
        assert!(vec_set::contains(&config.whitelist, &sender), ENotRwaWhitelist);

        // 判断project_key是否存在
        assert!(!object_bag::contains(&config.projects, project_key), EProjectKeyExists);

        // 初始化token，允许x_tokens为空，这样允许后面再追加
        let x_balance = utils::coins_into_balance(x_tokens);
        let x_balance_value = balance::value(&x_balance);

        let project_uid = object::new(ctx);
        let project_id = object::uid_to_inner(&project_uid);

        // 添加
        object_bag::add(&mut config.projects, project_key, RwaProject<X, Y> {
            id: project_uid,
            project_key,
            admin: sender,
            financier: sender,
            price: price_ratio,
            rwa_token_total_supply: x_balance_value,
            rwa_token_reserve: x_balance,
            total_revenue: 0,
            revenue_reserve: balance::zero(),
            dividend_records: object_bag::new(ctx)
        });

        event::emit(RwaProjectPublishEvent<X, Y> {
            project_id,
            project_key,
            admin: sender,
            financier: sender,
            price,
            rwa_token_total_supply: x_balance_value,
            rwa_token_reserve: x_balance_value,
            total_revenue: 0,
            revenue_reserve: 0
        });
    }

    // 获取rwa project信息
    public fun get_rwa_project_info<X, Y>(config: &RwaConfig, project_key: vector<u8>): RwaProjectInfo<X, Y> {
        assert!(config.version == VERSION, EVersionNotMatched);
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow<vector<u8>, RwaProject<X, Y>>(&config.projects, project_key);
        RwaProjectInfo<X, Y> {
            project_id: object::uid_to_inner(&project.id),
            project_key,
            admin: project.admin,
            financier: project.financier,
            price: ratio::partial(project.price, PRICE_SCALING),
            rwa_token_total_supply: project.rwa_token_total_supply,
            rwa_token_reserve: balance::value(&project.rwa_token_reserve),
            total_revenue: project.total_revenue,
            revenue_reserve: balance::value(&project.revenue_reserve),
        }
    }
    
    // 更改rwa项目管理员
    public entry fun set_rwa_project_admin<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, new_admin: address, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);
        // 判断是否有权限
        assert!(project.admin == sender, ENotProjectAdmin);

        let old_admin = project.admin;
        project.admin = new_admin;

        event::emit(RwaProjectAdminChangedEvent<X, Y> {
            old_admin,
            new_admin,
            project_id: object::uid_to_inner(&project.id),
            project_key
        })
    }

    // 更改rwa项目财务
    public entry fun set_rwa_project_financier<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, new_financier: address, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);
        // 判断是否有权限
        assert!(project.admin == sender, ENotProjectAdmin);

        let old_financier = project.financier;
        project.financier = new_financier;

        event::emit(RwaProjectFinancierChangedEvent<X, Y> {
            old_financier,
            new_financier,
            project_id: object::uid_to_inner(&project.id),
            project_key
        })
    }

    // 更改rwa token单价
    public entry fun set_rwa_project_token_price<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, new_price: u64, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);
        // 新单价
        let new_price_ratio = ratio::ratio(new_price, PRICE_SCALING);

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);
        // 判断是否有权限
        assert!(project.admin == sender, ENotProjectAdmin);

        let old_price = ratio::partial(project.price, PRICE_SCALING);
        project.price = new_price_ratio;

        event::emit(RwaProjectPriceChangedEvent<X, Y> {
            old_price,
            new_price,
            project_id: object::uid_to_inner(&project.id),
            project_key
        })
    }

    // 追加rwa project token
    public entry fun increase_rwa_project_token<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, x_tokens: vector<Coin<X>>, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);
        assert!(!vector::is_empty(&x_tokens), ECoinsEmpty);

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);
        // 判断是否有权限
        assert!(project.admin == sender, ENotProjectAdmin);
        
        let x_balance = utils::coins_into_balance(x_tokens);
        let x_balance_value = balance::value(&x_balance);
        project.rwa_token_total_supply = project.rwa_token_total_supply + x_balance_value;
        balance::join(&mut project.rwa_token_reserve, x_balance);

        event::emit(RwaProjectTokenIncreaseEvent<X, Y> {
            increase_supply: x_balance_value,
            project_id: object::uid_to_inner(&project.id),
            project_key
        });
    }

    // 购买rwa project token
    public entry fun buy_rwa_project_token<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, y_tokens: vector<Coin<Y>>, buy_num: u64, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);
        assert!(buy_num > 0, EBuyNumZero);
        assert!(!vector::is_empty(&y_tokens), ECoinsEmpty);
        assert!(!config.paused, ERwaPaused);

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);

        // 计算购买buy_num需要金额
        let amount = ratio::partial(project.price, buy_num);

        // 扣除用户的Coin<Y>，花费的Coin<Y>
        let spend_y_tokens = utils::merge_coins_to_amount_and_transfer_back_rest(y_tokens, amount, ctx);
        // 将Coin<Y>追加到合约账户中
        let spend_y_balance = coin::into_balance(spend_y_tokens);
        project.total_revenue = project.total_revenue + balance::value(&spend_y_balance);
        balance::join(&mut project.revenue_reserve, spend_y_balance);

        // 扣除合约账户的Balance<Y>
        let spend_x_balance = balance::split(&mut project.rwa_token_reserve, buy_num);
        // 转为Coin<X>，然后转给用户
        let spend_x_tokens = coin::from_balance(spend_x_balance, ctx);
        // 转为用户
        transfer::public_transfer(spend_x_tokens, sender);

        event::emit(RwaProjectTokenBuyEvent<X, Y> {
            user: sender,
            price: ratio::partial(project.price, PRICE_SCALING),
            spend_amount: amount,
            buy_num,
            project_id: object::uid_to_inner(&project.id),
            project_key
        });
    }

    // 提交分红批次（财务）
    // 允许一个批次，多次执行（防止参数分红账户过多，一次无法提交成功），通过批次标识区分开
    public entry fun submit_rwa_project_dividend_batch_record<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, record_key: vector<u8>, y_tokens: vector<Coin<Y>>, dividend_funds: u64, rwa_token_total_supply: u64, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);
        assert!(!config.paused, ERwaPaused);
        assert!(rwa_token_total_supply > 0, ERwaTokenTotalSupplyZero);

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);
        // 判断是否有权限
        assert!(project.financier == sender, ENotProjectFinancier);

        // 判断分红批次是否存在
        assert!(!object_bag::contains(&project.dividend_records, record_key), EDividendRecordExists);

        // 分红金额校验
        assert!(!vector::is_empty(&y_tokens), ECoinsEmpty);
        assert!(dividend_funds > 0, EDividendAmountZero);
        // 扣除财务账务的Coin<Y>
        let spend_y_tokens = utils::merge_coins_to_amount_and_transfer_back_rest(y_tokens, dividend_funds, ctx);
        // 将Coin<Y>追加到分红批次记录中
        let spend_y_balance = coin::into_balance(spend_y_tokens);

        // 记录ID
        let record_uid = object::new(ctx);
        let record_id = object::uid_to_inner(&record_uid);

        // 添加
        object_bag::add(&mut project.dividend_records, record_key, DividendBatchRecord<Y> {
            id: record_uid,
            project_key,
            record_key,
            rwa_token_total_supply,
            dividend_funds,
            dividend_funds_reserve: spend_y_balance,
            already_dividend_rwa_total: 0,
            dividend_list: table::new(ctx),
        });

        // 事件
        event::emit(RwaProjectDividendBatchRecordSubmitEvent<X, Y> {
            project_id: object::uid_to_inner(&project.id),
            project_key,
            record_id,
            record_key,
            rwa_token_total_supply,
            dividend_funds
        });
    }

    // 追加分红地址
    public entry fun additional_rwa_project_dividend_account<X, Y>(config: &mut RwaConfig, project_key: vector<u8>, record_key: vector<u8>, users: vector<address>, participating_dividends: vector<u64>, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);
        assert!(!config.paused, ERwaPaused);
        assert!(!vector::is_empty(&users), EParticipatingUserEmpty);
        assert!(vector::length(&users) != vector::length(&participating_dividends), EUsersAndParticipatingDividendsNotMatch);
        // 分红账户不能重复
        let set = vec_set::empty();
        let i = 0;
        let n = vector::length(&users);
        while (i < n) {
            let user = *vector::borrow(&users, i);
            assert!(!vec_set::contains(&set, &user), EDuplicateDividendAccount);
            i = i + 1;
        };

        let sender = tx_context::sender(ctx);

        // 判断project_key是否存在
        assert!(object_bag::contains(&config.projects, project_key), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_key);
        // 判断是否有权限
        assert!(project.financier == sender, ENotProjectFinancier);
        let project_id = object::uid_to_inner(&project.id);

        // 判断分红批次是否存在
        assert!(object_bag::contains(&project.dividend_records, record_key), EDividendRecordNotFound);

        // 分红记录
        let record = object_bag::borrow_mut<vector<u8>, DividendBatchRecord<Y>>(&mut project.dividend_records, record_key);
        let record_id = object::uid_to_inner(&record.id);

        let remaining_dividend_rwa_total = record.rwa_token_total_supply - record.already_dividend_rwa_total;
        assert!(remaining_dividend_rwa_total > 0, ERemainingDividendRwaTotalZero);

        // 防止越界，使用范围大一点的进行累计
        let participating_dividend_total: u128 = 0;
        let i = 0;
        let n = vector::length(&users);
        while (i < n) {
            participating_dividend_total = participating_dividend_total + (*vector::borrow(&participating_dividends, i) as u128);
            assert!(participating_dividend_total > (remaining_dividend_rwa_total as u128), EParticipatingDividendsOverlimit);
            i = i + 1;
        };
        // 判断金额是否够（理论上来说肯定是够的，因为财务提交后，用户只能提取自己的）
        let dividend_ratio = ratio::ratio(record.dividend_funds, record.rwa_token_total_supply);
        let need_dividend_funds = ratio::partial(dividend_ratio, (participating_dividend_total as u64));
        assert!(balance::value(&record.dividend_funds_reserve) > need_dividend_funds, EInsufficientDividendFundsReserve);
        // 校验没问题，再实际进行处理
        while (!vector::is_empty(&users)) {
            let user = vector::pop_back(&mut users);
            let participating_dividend = vector::pop_back(&mut participating_dividends);

            // 判断分红账户同一批次是否重复
            assert!(table::contains(&record.dividend_list, user), EDuplicateDividendAccount);
            // 添加分红账户信息
            table::add(&mut record.dividend_list, user, participating_dividend);

            // 计算用于分红
            let dividend_income = ratio::partial(dividend_ratio, participating_dividend);
            // 给用户转币
            // 扣除合约账户的Balance<Y>
            let spend_y_balance = balance::split(&mut record.dividend_funds_reserve, dividend_income);
            // 转为Coin<X>，然后转给用户
            let spend_y_tokens = coin::from_balance(spend_y_balance, ctx);
            // 转为用户
            transfer::public_transfer(spend_y_tokens, user);

            // 用户分红收益事件
            event::emit(RwaProjectUserDividendIncomeEvent<X, Y> {
                project_id,
                project_key,
                record_id,
                record_key,
                user,
                dividend_income
            });
        };
    }
}
