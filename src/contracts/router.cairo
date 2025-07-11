// SPDX-License-Identifier: MIT
#[starknet::contract]
pub mod ISPRouter {
    use core::array::{ArrayTrait};
    use core::traits::Into;
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, forward_lock
    };
    use ekubo::components::util::{serialize};
    use ekubo::types::i129::{i129};
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, SwapParameters, IForwardeeDispatcher, ILocker
    };
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::keys::{PoolKey};
    use starknet::{get_contract_address, get_caller_address, ContractAddress};
    use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess};
    use relaunch::contracts::internal_swap_pool::{ISPSwapData, ISPSwapResult, ClaimableFees};
    use relaunch::interfaces::Irouter::{IISPRouter};

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        native_token: ContractAddress,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        core: ICoreDispatcher,
        native_token: ContractAddress,
    ) {
        self.initialize_owned(owner);
        self.core.write(core);
        self.native_token.write(native_token);
    }

    // Route of the swap
    #[derive(Serde, Copy, Drop)]
    pub struct RouteNode {
        pub pool_key: PoolKey,
        pub sqrt_ratio_limit: u256,
        pub skip_ahead: u128,
    }

    // Amount of token to swap and its address
    #[derive(Serde, Copy, Drop)]
    pub struct TokenAmount {
        pub token: ContractAddress,
        pub amount: i129,
    }

    // Swap argument for multi multi-hop swaps
    #[derive(Serde, Drop)]
    pub struct Swap {
        pub route: Array<RouteNode>,
        pub token_amount: TokenAmount,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapExecuted {
        #[key]
        pub pool_key: PoolKey,
        #[key]
        pub user: ContractAddress,
        pub amount_in: u128,
        pub amount_out: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        SwapExecuted: SwapExecuted,
        #[flat]
        OwnedEvent: owned_component::Event,
    }

    // Storage for callback data
    #[derive(Copy, Drop, Serde)]
    struct CallbackData {
        caller: ContractAddress,
        pool_key: PoolKey,
        params: SwapParameters,
        token_in: ContractAddress,
        amount_in: u128,
        
    }

    #[abi(embed_v0)]
    impl ISPRouterImpl of IISPRouter<ContractState> {
        /// Main swap function - uses lock-forward pattern for ISP
        fn swap(
            ref self: ContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in: u128
        ) -> ISPSwapResult {
            // Verify this is an exact input swap
            assert(!params.amount.sign, 'Only exact input swaps');
            assert(params.amount.mag == amount_in, 'Amount mismatch');
            
            // Verify token_in matches the swap direction
            let is_token0_to_token1 = !params.is_token1;
            if is_token0_to_token1 {
                assert(token_in == pool_key.token0, 'Token mismatch');
            } else {
                assert(token_in == pool_key.token1, 'Token mismatch');
            }

            let caller = get_caller_address();
            
            // Prepare callback data
            let callback_data = CallbackData {
                caller,
                pool_key,
                params,
                token_in,
                amount_in,
                
            };
            
            // Use the helper to call core.lock with our callback
            call_core_with_callback::<CallbackData, ISPSwapResult>(
                self.core.read(),
                @callback_data
            )
        }
        
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Generate salt for user withdrawal from ISP
        fn _get_user_withdrawal_salt(
            self: @ContractState,
            user: ContractAddress
        ) -> felt252 {
            // Must match the salt generation in ISP component
            let user_felt: felt252 = user.into();
            user_felt + 'user_withdrawal'
        }
    }

    // Locker implementation - this is where the core logic happens
    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            
            // Consume the callback data
            let callback_data = consume_callback_data::<CallbackData>(core, data);
            
            // Prepare ISP swap data
            let isp_data = ISPSwapData {
                pool_key: callback_data.pool_key,
                params: callback_data.params,
                user: callback_data.caller,
                max_fee_amount: 0, // Not used for exact input swaps
            };
            
            // Forward to ISP extension and get result
            let isp_result: ISPSwapResult = forward_lock(
                core,
                IForwardeeDispatcher { contract_address: callback_data.pool_key.extension },
                @isp_data
            );
            
            
            // Handle token transfers at the END (till pattern)
            if callback_data.amount_in > 0 {
                let token_in_contract = IERC20Dispatcher { contract_address: callback_data.token_in };
                let amount_in_u256: u256 = callback_data.amount_in.into();
                token_in_contract.transferFrom(
                    callback_data.caller, 
                    get_contract_address(), 
                    amount_in_u256
                );
                core.pay(callback_data.token_in);
            }
            
            if isp_result.output_amount > 0 {
                core.withdraw(isp_result.output_token, callback_data.caller, isp_result.output_amount);
            }
            
            // Emit event
            self.emit(SwapExecuted {
                pool_key: callback_data.pool_key,
                user: callback_data.caller,
                amount_in: callback_data.amount_in,
                amount_out: isp_result.output_amount,
            });
            
            // Return the result using serialize helper
            serialize(@isp_result).span()
        }
    }
}
