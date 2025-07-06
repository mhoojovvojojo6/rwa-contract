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

    // 版本
    const VERSION: u64 = 0;

    // 错误码
    const EVersionNotMatched: u64 = 100000;             // 版本不一致
    const ENotRWAAdmin: u64 = 100001;                   // 非RWA ADMIN
    const ENotProjectAdmin: u64 = 10002;                // 非RWA项目ADMIN
    const ENotProjectFinancier: u64 = 10003;            // 非RWA项目财务
    const ENotRwaWhitelist: u64 = 10004;                // 非RWA白名单，不允许发布RWA项目
    const EAlreadyRwaWhitelist: u64 = 10005;            // 已经是RWA白名单
    const EProjectIdExists: u64 = 10006;                // project_id重复
    const ERwaProjectNotFound: u64 = 10007;             // RWA project项目未找到
    const ECoinsEmpty: u64 = 10008;                     // 输入vector<Coin>为空

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
        project_id: vector<u8>,
        // 项目管理员
        admin: address,
        // 财务
        financier: address,
        // RWA代币发行总量
        rwa_token_total_supply: u64,
        // RWA代币剩余量
        rwa_token_reserve: Balance<X>,
        // 用户购买RWA代币收入总量
        total_revenue: u64,
        // 用户购买RWA代币收入剩余量（因为存在提现/分红等行为，该量总量不等于total_revenue，并且财务也可能充钱进去）
        revenue_reserve: Balance<Y>,        
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
    public entry fun set_rwa_admin(config: &mut RwaConfig, new_rwa_admin: address, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        config.admin = new_rwa_admin;
    }

    // 启用或者关闭
    public entry fun set_rwa_paused(config: &mut RwaConfig, paused: bool, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        config.paused = paused;
    }

    // 添加白名单
    public entry fun add_rwa_whitelist(config: &mut RwaConfig, user: address, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        // 白名单已经存在
        assert!(!vec_set::contains(&config.whitelist, &user), EAlreadyRwaWhitelist);
        vec_set::insert(&mut config.whitelist, user);
    }

    // 移除白名单
    public entry fun remove_rwa_whitelist(config: &mut RwaConfig, user: address, ctx: &mut tx_context::TxContext) {
        assert!(config.admin == tx_context::sender(ctx), ENotRWAAdmin);
        assert!(config.version == VERSION, EVersionNotMatched);
        // 白名单不存在
        assert!(vec_set::contains(&config.whitelist, &user), ENotRwaWhitelist);
        vec_set::remove(&mut config.whitelist, &user);
    }

    // 发布一个RWA项目
    public entry fun publish_rwa_project<X, Y>(config: &mut RwaConfig, project_id: vector<u8>, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);

        let sender = tx_context::sender(ctx);
        // 非白名单不允许发布RWA项目
        assert!(vec_set::contains(&config.whitelist, &sender), ENotRwaWhitelist);

        // 判断project_id是否存在
        assert!(!object_bag::contains(&config.projects, project_id), EProjectIdExists);

        // 添加
        object_bag::add(&mut config.projects, project_id, RwaProject<X, Y> {
            id: object::new(ctx),
            project_id,
            admin: sender,
            financier: sender,
            rwa_token_total_supply: 0,
            rwa_token_reserve: balance::zero(),
            total_revenue: 0,
            revenue_reserve: balance::zero(),
        });
    }

    // 追加rwa project token
    public entry fun increase_rwa_project_token<X, Y>(config: &mut RwaConfig, project_id: vector<u8>, x_tokens: vector<Coin<X>>, ctx: &mut tx_context::TxContext) {
        assert!(config.version == VERSION, EVersionNotMatched);
        assert!(!vector::is_empty(&x_tokens), ECoinsEmpty);

        let sender = tx_context::sender(ctx);

        // 判断project_id是否存在
        assert!(object_bag::contains(&config.projects, project_id), ERwaProjectNotFound);

        let project = object_bag::borrow_mut<vector<u8>, RwaProject<X, Y>>(&mut config.projects, project_id);
        
        let x_balance = utils::coins_into_balance(x_tokens);
        project.rwa_token_total_supply = project.rwa_token_total_supply + balance::value(&x_balance);
        balance::join(&mut project.rwa_token_reserve, x_balance);
    }
}
