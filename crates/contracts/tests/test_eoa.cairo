use contracts::account_contract::AccountContract::TransactionExecuted;
use contracts::account_contract::{AccountContract, IAccountDispatcher, IAccountDispatcherTrait};
use contracts::kakarot_core::{
    IKakarotCore, KakarotCore, KakarotCore::KakarotCoreInternal,
    interface::IExtendedKakarotCoreDispatcherTrait
};
use contracts::test_contracts::test_upgradeable::{
    IMockContractUpgradeableDispatcher, IMockContractUpgradeableDispatcherTrait,
    MockContractUpgradeableV1
};
use contracts::test_data::{counter_evm_bytecode, eip_2930_rlp_encoded_counter_inc_tx,};
use contracts::test_utils::{
    setup_contracts_for_testing, deploy_eoa, deploy_contract_account,
    fund_account_with_native_token, call_transaction
};
use core::array::SpanTrait;
use core::box::BoxTrait;
use core::starknet::account::{Call};
use core::starknet::class_hash::Felt252TryIntoClassHash;
use core::starknet::{
    deploy_syscall, ContractAddress, ClassHash, VALIDATED, get_contract_address,
    contract_address_const, EthAddress, eth_signature::{Signature}, get_tx_info, Event
};

use evm::model::{Address, AddressTrait};
use evm::test_utils::{
    kakarot_address, evm_address, other_evm_address, other_starknet_address, eoa_address, chain_id,
    tx_gas_limit, gas_price, VMBuilderTrait
};
use openzeppelin::token::erc20::interface::IERC20CamelDispatcherTrait;
use snforge_std::{
    start_cheat_caller_address, stop_cheat_caller_address, start_cheat_signature,
    stop_cheat_signature, start_cheat_chain_id, stop_cheat_chain_id, start_cheat_transaction_hash,
    stop_cheat_transaction_hash, spy_events, EventSpyTrait, EventsFilterTrait, CheatSpan,
    cheat_caller_address
};
use snforge_utils::snforge_utils::{ContractEvents, ContractEventsTrait, EventsFilterBuilderTrait};
use utils::eth_transaction::{
    TransactionType, EthereumTransaction, EthereumTransactionTrait, LegacyTransaction
};
use utils::helpers::{U8SpanExTrait, u256_to_bytes_array};
use utils::serialization::{serialize_bytes, serialize_transaction_signature};
use utils::test_data::{legacy_rlp_encoded_tx, eip_2930_encoded_tx, eip_1559_encoded_tx};


#[test]
fn test_get_evm_address() {
    let expected_address: EthAddress = eoa_address();
    let (_, kakarot_core) = setup_contracts_for_testing();

    let eoa_contract = deploy_eoa(kakarot_core, eoa_address());

    assert(eoa_contract.get_evm_address() == expected_address, 'wrong evm_address');
}

#[test]
#[available_gas(200000000000000)]
fn test___execute__a() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();

    let evm_address = evm_address();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);

    let kakarot_address = kakarot_core.contract_address;

    deploy_contract_account(kakarot_core, other_evm_address(), counter_evm_bytecode());

    start_cheat_caller_address(kakarot_address, eoa);
    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    // Then
    // selector: function get()
    let data_get_tx = [0x6d, 0x4c, 0xe6, 0x3c].span();

    // check counter value is 0 before doing inc
    let tx = call_transaction(chain_id(), Option::Some(other_evm_address()), data_get_tx);

    let (_, return_data) = kakarot_core
        .eth_call(origin: evm_address, tx: EthereumTransaction::LegacyTransaction(tx),);

    assert_eq!(return_data, u256_to_bytes_array(0).span());

    // perform inc on the counter
    let encoded_tx = eip_2930_rlp_encoded_counter_inc_tx();

    let call = Call {
        to: kakarot_address,
        selector: selector!("eth_send_transaction"),
        calldata: serialize_bytes(encoded_tx).span()
    };

    start_cheat_transaction_hash(eoa, selector!("transaction_hash"));
    cheat_caller_address(eoa, contract_address_const::<0>(), CheatSpan::TargetCalls(1));
    let mut spy = spy_events();
    let result = eoa_contract.__execute__(array![call]);
    assert_eq!(result.len(), 1);

    let expected_event = AccountContract::Event::transaction_executed(
        AccountContract::TransactionExecuted {
            response: *result.span()[0], success: true, gas_used: 0
        }
    );
    let mut keys = array![];
    let mut data = array![];
    expected_event.append_keys_and_data(ref keys, ref data);
    let mut contract_events = EventsFilterBuilderTrait::from_events(@spy.get_events())
        .with_contract_address(eoa)
        .with_keys(keys.span())
        .build();

    let mut received_keys = contract_events.events[0].keys.span();
    let mut received_data = contract_events.events[0].data.span();
    let deserialized_received: AccountContract::Event = Event::deserialize(
        ref received_keys, ref received_data
    )
        .unwrap();
    if let AccountContract::Event::transaction_executed(transaction_executed) =
        deserialized_received {
        let expected_response = *result.span()[0];
        let expected_success = true;
        let not_expected_gas_used = 0;
        assert_eq!(transaction_executed.response, expected_response);
        assert_eq!(transaction_executed.success, expected_success);
        assert_ne!(transaction_executed.gas_used, not_expected_gas_used);
    } else {
        panic!("Expected transaction_executed event");
    }
    // check counter value has increased
    let tx = call_transaction(chain_id(), Option::Some(other_evm_address()), data_get_tx);
    let (_, return_data) = kakarot_core
        .eth_call(origin: evm_address, tx: EthereumTransaction::LegacyTransaction(tx),);
    assert_eq!(return_data, u256_to_bytes_array(1).span());
}

#[test]
#[should_panic(expected: 'EOA: multicall not supported')]
fn test___execute___should_fail_with_zero_calls() {
    let (_, kakarot_core) = setup_contracts_for_testing();

    let eoa_contract = deploy_eoa(kakarot_core, eoa_address());
    let eoa_contract = IAccountDispatcher { contract_address: eoa_contract.contract_address };

    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    eoa_contract.__execute__(array![]);
}

#[test]
#[should_panic(expected: 'EOA: reentrant call')]
fn test___validate__fail__caller_not_0() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address = evm_address();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);
    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    start_cheat_caller_address(eoa_contract.contract_address, other_starknet_address());

    let calls = array![
        Call {
            to: kakarot_core.contract_address,
            selector: selector!("eth_send_transaction"),
            calldata: [].span()
        }
    ];
    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<1>(), CheatSpan::TargetCalls(1)
    );
    eoa_contract.__validate__(calls);
}

#[test]
#[should_panic(expected: 'EOA: multicall not supported')]
fn test___validate__fail__call_data_len_not_1() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address = evm_address();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);
    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    let calls = array![];
    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    eoa_contract.__validate__(calls);
}

#[test]
#[should_panic(expected: 'to is not kakarot core')]
fn test___validate__fail__to_address_not_kakarot_core() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address = evm_address();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);
    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    // to reproduce locally:
    // run: cp .env.example .env
    // bun install & bun run scripts/compute_rlp_encoding.ts
    let signature = Signature {
        r: 0xaae7c4f6e4caa03257e37a6879ed5b51a6f7db491d559d10a0594f804aa8d797,
        s: 0x2f3d9634f8cb9b9a43b048ee3310be91c2d3dc3b51a3313b473ef2260bbf6bc7,
        y_parity: true
    };
    start_cheat_signature(
        eoa_contract.contract_address,
        serialize_transaction_signature(signature, TransactionType::Legacy, 1).span()
    );

    let call = Call {
        to: other_starknet_address(),
        selector: selector!("eth_send_transaction"),
        calldata: [].span()
    };

    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    eoa_contract.__validate__(array![call]);
}

#[test]
#[should_panic(expected: "Validate: selector must be eth_send_transaction")]
fn test___validate__fail__selector_not_eth_send_transaction() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address = evm_address();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);
    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    start_cheat_chain_id(eoa_contract.contract_address, chain_id().into());
    let mut vm = VMBuilderTrait::new_with_presets().build();
    let chain_id = vm.env.chain_id;
    start_cheat_caller_address(eoa_contract.contract_address, contract_address_const::<0>());

    // to reproduce locally:
    // run: cp .env.example .env
    // bun install & bun run scripts/compute_rlp_encoding.ts
    let signature = Signature {
        r: 0xaae7c4f6e4caa03257e37a6879ed5b51a6f7db491d559d10a0594f804aa8d797,
        s: 0x2f3d9634f8cb9b9a43b048ee3310be91c2d3dc3b51a3313b473ef2260bbf6bc7,
        y_parity: true
    };
    start_cheat_signature(
        eoa_contract.contract_address,
        serialize_transaction_signature(signature, TransactionType::Legacy, chain_id).span()
    );

    let call = Call {
        to: kakarot_core.contract_address, selector: selector!("eth_call"), calldata: [].span()
    };

    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    eoa_contract.__validate__(array![call]);
}

#[test]
fn test___validate__legacy_transaction() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address: EthAddress = 0xaA36F24f65b5F0f2c642323f3d089A3F0f2845Bf_u256.into();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);

    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    start_cheat_chain_id(eoa_contract.contract_address, chain_id().into());
    let mut vm = VMBuilderTrait::new_with_presets().build();
    let chain_id = vm.env.chain_id;

    // to reproduce locally:
    // run: cp .env.example .env
    // bun install & bun run scripts/compute_rlp_encoding.ts
    let signature = Signature {
        r: 0x5e5202c7e9d6d0964a1f48eaecf12eef1c3cafb2379dfeca7cbd413cedd4f2c7,
        s: 0x66da52d0b666fc2a35895e0c91bc47385fe3aa347c7c2a129ae2b7b06cb5498b,
        y_parity: false
    };
    start_cheat_signature(
        eoa_contract.contract_address,
        serialize_transaction_signature(signature, TransactionType::Legacy, chain_id).span()
    );

    let call = Call {
        to: kakarot_core.contract_address,
        selector: selector!("eth_send_transaction"),
        calldata: serialize_bytes(legacy_rlp_encoded_tx()).span()
    };

    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    let result = eoa_contract.__validate__(array![call]);
    assert(result == VALIDATED, 'validation failed');
}

#[test]
fn test___validate__eip_2930_transaction() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address: EthAddress = 0xaA36F24f65b5F0f2c642323f3d089A3F0f2845Bf_u256.into();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);

    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    start_cheat_chain_id(eoa_contract.contract_address, chain_id().into());
    let mut vm = VMBuilderTrait::new_with_presets().build();
    let chain_id = vm.env.chain_id;

    // to reproduce locally:
    // run: cp .env.example .env
    // bun install & bun run scripts/compute_rlp_encoding.ts
    let signature = Signature {
        r: 0xbced8d81c36fe13c95b883b67898b47b4b70cae79e89fa27856ddf8c533886d1,
        s: 0x3de0109f00bc3ed95ffec98edd55b6f750cb77be8e755935dbd6cfec59da7ad0,
        y_parity: true
    };

    start_cheat_signature(
        eoa_contract.contract_address,
        serialize_transaction_signature(signature, TransactionType::EIP2930, chain_id).span()
    );

    let call = Call {
        to: kakarot_core.contract_address,
        selector: selector!("eth_send_transaction"),
        calldata: serialize_bytes(eip_2930_encoded_tx()).span()
    };

    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    let result = eoa_contract.__validate__(array![call]);
    assert(result == VALIDATED, 'validation failed');
}

#[test]
fn test___validate__eip_1559_transaction() {
    let (native_token, kakarot_core) = setup_contracts_for_testing();
    let evm_address: EthAddress = 0xaA36F24f65b5F0f2c642323f3d089A3F0f2845Bf_u256.into();
    let eoa = kakarot_core.deploy_externally_owned_account(evm_address);
    fund_account_with_native_token(eoa, native_token, 0xfffffffffffffffffffffffffff);

    let eoa_contract = IAccountDispatcher { contract_address: eoa };

    start_cheat_chain_id(eoa_contract.contract_address, chain_id().into());
    let mut vm = VMBuilderTrait::new_with_presets().build();
    let chain_id = vm.env.chain_id;

    // to reproduce locally:
    // run: cp .env.example .env
    // bun install & bun run scripts/compute_rlp_encoding.ts
    let signature = Signature {
        r: 0x0f9a716653c19fefc240d1da2c5759c50f844fc8835c82834ea3ab7755f789a0,
        s: 0x71506d904c05c6e5ce729b5dd88bcf29db9461c8d72413b864923e8d8f6650c0,
        y_parity: true
    };

    let call = Call {
        to: kakarot_core.contract_address,
        selector: selector!("eth_send_transaction"),
        calldata: serialize_bytes(eip_1559_encoded_tx()).span()
    };

    start_cheat_signature(
        eoa_contract.contract_address,
        serialize_transaction_signature(signature, TransactionType::EIP1559, chain_id).span()
    );
    cheat_caller_address(
        eoa_contract.contract_address, contract_address_const::<0>(), CheatSpan::TargetCalls(1)
    );
    let result = eoa_contract.__validate__(array![call]);
    assert(result == VALIDATED, 'validation failed');
}
