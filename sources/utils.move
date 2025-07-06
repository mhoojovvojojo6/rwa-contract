module rwa::utils {
    use std::vector;
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};
    use sui::pay;
    use sui::transfer;
    use sui::balance::{Self, Balance};

    // 错误码
    const ENotEnoughBalance: u64 = 101001; // 没有足够的额度

    public fun coins_into_balance<T>(cs: vector<Coin<T>>): Balance<T> {
        let result = balance::zero();
        while (!vector::is_empty(&cs)) {
            let c = vector::pop_back(&mut cs);
            balance::join(&mut result, coin::into_balance(c));
        };
        vector::destroy_empty(cs);

        result
    }

    public fun merge_coins<T>(cs: vector<Coin<T>>, ctx: &mut TxContext): Coin<T> {
        if (vector::length(&cs) == 0) {
            let c = coin::zero<T>(ctx);
            vector::destroy_empty(cs);
            c
        }
        else {
            let c = vector::pop_back(&mut cs);
            pay::join_vec(&mut c, cs);
            c
        }
    }

    public fun merge_coins_to_amount_and_transfer_back_rest<T>(cs: vector<Coin<T>>, amount: u64, ctx: &mut TxContext): Coin<T> {
        let c = merge_coins(cs, ctx);
        assert!(coin::value(&c) >= amount, ENotEnoughBalance);

        let c_out = coin::split(&mut c, amount, ctx);

        let sender = tx_context::sender(ctx);
        transfer_or_destroy_zero(c, sender);
        
        c_out
    }

    public fun transfer_or_destroy_zero<X>(c: Coin<X>, addr: address) {
        if (coin::value(&c) > 0) {
            transfer::public_transfer(c, addr);
        }
        else {
            coin::destroy_zero(c);
        }
    }
}