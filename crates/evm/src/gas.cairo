use core::cmp::min;
use core::starknet::EthAddress;
use utils::eth_transaction::{AccessListItem, EthereumTransaction, EthereumTransactionTrait};
use utils::helpers;

//! Gas costs for EVM operations
//! Code is based on alloy project
//! Source: <https://github.com/bluealloy/revm/blob/main/crates/interpreter/src/gas/constants.rs>

const ZERO: u128 = 0;
const BASE: u128 = 2;
const VERYLOW: u128 = 3;
const LOW: u128 = 5;
const MID: u128 = 8;
const HIGH: u128 = 10;
const JUMPDEST: u128 = 1;
const SELFDESTRUCT: u128 = 5000;
const CREATE: u128 = 32000;
const CALLVALUE: u128 = 9000;
const NEWACCOUNT: u128 = 25000;
const EXP: u128 = 10;
const EXP_GAS_PER_BYTE: u128 = 50;
const MEMORY: u128 = 3;
const LOG: u128 = 375;
const LOGDATA: u128 = 8;
const LOGTOPIC: u128 = 375;
const KECCAK256: u128 = 30;
const KECCAK256WORD: u128 = 6;
const COPY: u128 = 3;
const BLOCKHASH: u128 = 20;
const CODEDEPOSIT: u128 = 200;

const SSTORE_SET: u128 = 20000;
const SSTORE_RESET: u128 = 5000;
const REFUND_SSTORE_CLEARS: u128 = 4800;

const TRANSACTION_ZERO_DATA: u128 = 4;
const TRANSACTION_NON_ZERO_DATA_INIT: u128 = 16;
const TRANSACTION_NON_ZERO_DATA_FRONTIER: u128 = 68;
const TRANSACTION_BASE_COST: u128 = 21000;
const TRANSACTION_CREATE_COST: u128 = 32000;

// Berlin EIP-2929 constants
const ACCESS_LIST_ADDRESS: u128 = 2400;
const ACCESS_LIST_STORAGE_KEY: u128 = 1900;
const COLD_SLOAD_COST: u128 = 2100;
const COLD_ACCOUNT_ACCESS_COST: u128 = 2600;
const WARM_ACCESS_COST: u128 = 100;

/// EIP-3860 : Limit and meter initcode
const INITCODE_WORD_COST: u128 = 2;

const CALL_STIPEND: u128 = 2300;

// EIP-4844
pub const BLOB_HASH_COST: u128 = 3;

/// Defines the gas cost and stipend for executing call opcodes.
///
/// # Struct fields
///
/// * `cost`: The non-refundable portion of gas reserved for executing the call opcode.
/// * `stipend`: The portion of gas available to sub-calls that is refundable if not consumed.
#[derive(Drop)]
struct MessageCallGas {
    cost: u128,
    stipend: u128,
}

/// Defines the new size and the expansion cost after memory expansion.
///
/// # Struct fields
///
/// * `new_size`: The new size of the memory after extension.
/// * `expansion_cost`: The cost of the memory extension.
#[derive(Drop)]
struct MemoryExpansion {
    new_size: u32,
    expansion_cost: u128,
}

/// Calculates the maximum gas that is allowed for making a message call.
///
/// # Arguments
/// * `gas`: The gas available for the message call.
///
/// # Returns
/// * The maximum gas allowed for the message call.
fn max_message_call_gas(gas: u128) -> u128 {
    gas - (gas / 64)
}

/// Calculates the MessageCallGas (cost and stipend) for executing call Opcodes.
///
/// # Parameters
///
/// * `value`: The amount of native token that needs to be transferred.
/// * `gas`: The amount of gas provided to the message-call.
/// * `gas_left`: The amount of gas left in the current frame.
/// * `memory_cost`: The amount needed to extend the memory in the current frame.
/// * `extra_gas`: The amount of gas needed for transferring value + creating a new account inside a
/// message call.
/// * `call_stipend`: The amount of stipend provided to a message call to execute code while
/// transferring value(native token).
///
/// # Returns
///
/// * `message_call_gas`: `MessageCallGas`
fn calculate_message_call_gas(
    value: u256, gas: u128, gas_left: u128, memory_cost: u128, extra_gas: u128
) -> MessageCallGas {
    let call_stipend = if value == 0 {
        0
    } else {
        CALL_STIPEND
    };
    let gas = if gas_left < extra_gas + memory_cost {
        gas
    } else {
        min(gas, max_message_call_gas(gas_left - memory_cost - extra_gas))
    };

    return MessageCallGas { cost: gas + extra_gas, stipend: gas + call_stipend };
}


/// Calculates the gas cost for allocating memory
/// to the smallest multiple of 32 bytes,
/// such that the allocated size is at least as big as the given size.
///
/// To optimize computations on u128 and avoid overflows, we compute size_in_words / 512
///  instead of size_in_words * size_in_words / 512. Then we recompute the
///  resulting quotient: x^2 = 512q + r becomes
///  x = 512 q0 + r0 => x^2 = 512(512 q0^2 + 2 q0 r0) + r0^2
///  r0^2 = 512 q1 + r1
///  x^2 = 512(512 q0^2 + 2 q0 r0 + q1) + r1
///  q = 512 * q0 * q0 + 2 * q0 * r0 + q1
/// # Parameters
///
/// * `size_in_bytes` - The size of the data in bytes.
///
/// # Returns
///
/// * `total_gas_cost` - The gas cost for storing data in memory.
fn calculate_memory_gas_cost(size_in_bytes: usize) -> u128 {
    let _512: NonZero<u128> = 512_u128.try_into().unwrap();
    let size_in_words = (size_in_bytes + 31) / 32;
    let linear_cost = size_in_words.into() * MEMORY;

    let (q0, r0) = DivRem::div_rem(size_in_words.into(), _512);
    let (q1, _) = DivRem::div_rem(r0 * r0, _512);
    let quadratic_cost = 512 * q0 * q0 + 2 * q0 * r0 + q1;

    linear_cost + quadratic_cost
}


/// Calculates memory expansion based on multiple memory operations.
///
/// # Arguments
///
/// * `current_size`: Current size of the memory.
/// * `operations`: A span of tuples (offset, size) representing memory operations.
///
/// # Returns
///
/// * `MemoryExpansion`: New size and expansion cost.
fn memory_expansion(current_size: usize, operations: Span<(usize, usize)>) -> MemoryExpansion {
    let mut max_size = current_size;

    for (
        offset, size
    ) in operations {
        if *size != 0 {
            let end = *offset + *size;
            if end > max_size {
                max_size = end;
            }
        }
    };

    let new_size = helpers::ceil32(max_size);

    if new_size <= current_size {
        return MemoryExpansion { new_size: current_size, expansion_cost: 0 };
    }

    let prev_cost = calculate_memory_gas_cost(current_size);
    let new_cost = calculate_memory_gas_cost(new_size);
    let expansion_cost = new_cost - prev_cost;
    MemoryExpansion { new_size, expansion_cost }
}

/// Calculates the gas to be charged for the init code in CREATE/CREATE2
/// opcodes as well as create transactions.
///
/// # Arguments
///
/// * `code_size` - The size of the init code
///
/// # Returns
///
/// * `init_code_gas` - The gas to be charged for the init code.
#[inline(always)]
fn init_code_cost(code_size: usize) -> u128 {
    let code_size_in_words = helpers::ceil32(code_size) / 32;
    code_size_in_words.into() * INITCODE_WORD_COST
}

/// Calculates the gas that is charged before execution is started.
///
/// The intrinsic cost of the transaction is charged before execution has
/// begun. Functions/operations in the EVM cost money to execute so this
/// intrinsic cost is for the operations that need to be paid for as part of
/// the transaction. Data transfer, for example, is part of this intrinsic
/// cost. It costs ether to send data over the wire and that ether is
/// accounted for in the intrinsic cost calculated in this function. This
/// intrinsic cost must be calculated and paid for before execution in order
/// for all operations to be implemented.
///
/// Reference:
/// https://github.com/ethereum/execution-specs/blob/master/src/ethereum/shanghai/fork.py#L689
fn calculate_intrinsic_gas_cost(tx: @EthereumTransaction) -> u128 {
    let mut data_cost: u128 = 0;

    let target = tx.destination();
    let mut calldata = tx.calldata();
    let calldata_len: usize = calldata.len();

    for data in calldata {
        data_cost +=
            if *data == 0 {
                TRANSACTION_ZERO_DATA
            } else {
                TRANSACTION_NON_ZERO_DATA_INIT
            };
    };

    let create_cost = if target.is_none() {
        TRANSACTION_CREATE_COST + init_code_cost(calldata_len)
    } else {
        0
    };

    let access_list_cost = if let Option::Some(mut access_list) = tx.try_access_list() {
        let mut access_list_cost: u128 = 0;
        for access_list_item in access_list {
            let AccessListItem { ethereum_address: _, storage_keys } = *access_list_item;
            access_list_cost += ACCESS_LIST_ADDRESS
                + (ACCESS_LIST_STORAGE_KEY * storage_keys.len().into());
        };
        access_list_cost
    } else {
        0
    };

    TRANSACTION_BASE_COST + data_cost + create_cost + access_list_cost
}

#[cfg(test)]
mod tests {
    use core::option::OptionTrait;
    use core::starknet::EthAddress;

    use evm::gas::{
        calculate_intrinsic_gas_cost, calculate_memory_gas_cost, ACCESS_LIST_ADDRESS,
        ACCESS_LIST_STORAGE_KEY
    };
    use evm::test_utils::evm_address;
    use utils::eth_transaction::{
        EthereumTransaction, LegacyTransaction, AccessListTransaction, EthereumTransactionTrait,
        AccessListItem
    };
    use utils::helpers::{U256Trait, ToBytes};

    #[test]
    fn test_calculate_intrinsic_gas_cost() {
        // RLP decoded value: (https://toolkit.abdk.consulting/ethereum#rlp,transaction)
        // ["0xc9", "0x81", "0xf7", "0x81", "0x80", "0x81", "0x84", "0x00", "0x00", "0x12"]
        //   16      16      16       16      16      16      16      4        4      16
        //   + 21000
        //   + 0
        //   ---------------------------
        //   = 21136
        let rlp_encoded: u256 = 0xc981f781808184000012;

        let calldata = rlp_encoded.to_be_bytes();
        let destination: Option<EthAddress> = 'vitalik.eth'.try_into();

        let tx: EthereumTransaction = EthereumTransaction::LegacyTransaction(
            LegacyTransaction {
                nonce: 0,
                gas_price: 50,
                gas_limit: 433926,
                destination,
                amount: 1,
                calldata,
                chain_id: 0x1
            }
        );

        let expected_cost: u128 = 21136;
        let out_cost: u128 = calculate_intrinsic_gas_cost(@tx);

        assert_eq!(out_cost, expected_cost, "wrong cost");
    }

    #[test]
    fn test_calculate_intrinsic_gas_cost_with_access_list() {
        // RLP decoded value: (https://toolkit.abdk.consulting/ethereum#rlp,transaction)
        // ["0xc9", "0x81", "0xf7", "0x81", "0x80", "0x81", "0x84", "0x00", "0x00", "0x12"]
        //   16      16      16       16      16      16      16      4        4      16
        //   + 21000
        //   + 0
        //   ---------------------------
        //   = 21136
        let rlp_encoded: u256 = 0xc981f781808184000012;

        let calldata = rlp_encoded.to_be_bytes();
        let destination: Option<EthAddress> = 'vitalik.eth'.try_into();

        let access_list = [
            AccessListItem { ethereum_address: evm_address(), storage_keys: [1, 2, 3, 4, 5].span() }
        ].span();

        let tx: EthereumTransaction = EthereumTransaction::AccessListTransaction(
            AccessListTransaction {
                nonce: 0,
                gas_price: 50,
                gas_limit: 433926,
                destination,
                amount: 1,
                calldata,
                chain_id: 0x1,
                access_list
            }
        );

        let expected_cost: u128 = 21136 + ACCESS_LIST_ADDRESS + 5 * ACCESS_LIST_STORAGE_KEY;
        let out_cost: u128 = calculate_intrinsic_gas_cost(@tx);

        assert_eq!(out_cost, expected_cost, "wrong cost");
    }


    #[test]
    fn test_calculate_intrinsic_gas_cost_without_destination() {
        // RLP decoded value: (https://toolkit.abdk.consulting/ethereum#rlp,transaction)
        // ["0xc9", "0x81", "0xf7", "0x81", "0x80", "0x81", "0x84", "0x00", "0x00", "0x12"]
        //   16      16      16       16      16      16      16      4        4      16
        //   + 21000
        //   + (32000 + 2)
        //   ---------------------------
        //   = 53138
        let rlp_encoded: u256 = 0xc981f781808184000012;

        let calldata = rlp_encoded.to_be_bytes();

        let tx: EthereumTransaction = EthereumTransaction::LegacyTransaction(
            LegacyTransaction {
                nonce: 0,
                gas_price: 50,
                gas_limit: 433926,
                destination: Option::None(()),
                amount: 1,
                calldata,
                chain_id: 0x1
            }
        );

        let expected_cost: u128 = 53138;
        let out_cost: u128 = calculate_intrinsic_gas_cost(@tx);

        assert_eq!(out_cost, expected_cost, "wrong cost");
    }

    #[test]
    fn test_calculate_memory_allocation_cost() {
        let size_in_bytes: usize = 10018613;
        let expected_cost: u128 = 192385220;
        let out_cost: u128 = calculate_memory_gas_cost(size_in_bytes);
        assert_eq!(out_cost, expected_cost, "wrong cost");
    }
}
