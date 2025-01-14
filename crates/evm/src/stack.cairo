use core::fmt::{Debug, Formatter, Error, Display};
use core::nullable::{NullableTrait};
use core::num::traits::Bounded;
use core::starknet::{StorageBaseAddress, EthAddress};
//! Stack implementation.
//! # Example
//! ```
//! use evm::stack::StackTrait;
//!
//! // Create a new stack instance.
//! let mut stack = StackTrait::new();
//! let val_1: u256 = 1.into();
//! let val_2: u256 = 1.into();

//! stack.push(val_1)?;
//! stack.push(val_2)?;

//! let value = stack.pop()?;
//! ```
use evm::errors::{ensure, EVMError, TYPE_CONVERSION_ERROR};

use utils::constants;
use utils::i256::i256;
use utils::traits::{TryIntoResult};


//TODO(optimization): make len `felt252` based to avoid un-necessary checks
#[derive(Destruct, Default)]
struct Stack {
    items: Felt252Dict<Nullable<u256>>,
    len: usize,
}

trait StackTrait {
    fn new() -> Stack;
    fn push(ref self: Stack, item: u256) -> Result<(), EVMError>;
    fn pop(ref self: Stack) -> Result<u256, EVMError>;
    fn pop_usize(ref self: Stack) -> Result<usize, EVMError>;
    fn pop_u64(ref self: Stack) -> Result<u64, EVMError>;
    fn pop_u128(ref self: Stack) -> Result<u128, EVMError>;
    fn pop_saturating_u128(ref self: Stack) -> Result<u128, EVMError>;
    fn pop_i256(ref self: Stack) -> Result<i256, EVMError>;
    fn pop_eth_address(ref self: Stack) -> Result<EthAddress, EVMError>;
    fn pop_n(ref self: Stack, n: usize) -> Result<Array<u256>, EVMError>;
    fn peek(ref self: Stack) -> Option<u256>;
    fn peek_at(ref self: Stack, index: usize) -> Result<u256, EVMError>;
    fn swap_i(ref self: Stack, index: usize) -> Result<(), EVMError>;
    fn len(self: @Stack) -> usize;
    fn is_empty(self: @Stack) -> bool;
}

impl StackImpl of StackTrait {
    #[inline(always)]
    fn new() -> Stack {
        Default::default()
    }

    /// Pushes a new bytes32 word onto the stack.
    ///
    /// When pushing an item to the stack, we will compute
    /// an index which corresponds to the index in the dict the item will be stored at.
    /// The internal index is computed as follows:
    ///
    /// index = len(Stack_i) + i * STACK_SEGMENT_SIZE
    ///
    /// # Errors
    ///
    /// If the stack is full, returns with a StackOverflow error.
    #[inline(always)]
    fn push(ref self: Stack, item: u256) -> Result<(), EVMError> {
        let length = self.len();
        // we can store at most 1024 256-bits words
        ensure(length != constants::STACK_MAX_DEPTH, EVMError::StackOverflow)?;

        self.items.insert(length.into(), NullableTrait::new(item));
        self.len += 1;
        Result::Ok(())
    }

    /// Pops the top item off the stack.
    ///
    /// # Errors
    ///
    /// If the stack is empty, returns with a StackOverflow error.
    #[inline(always)]
    fn pop(ref self: Stack) -> Result<u256, EVMError> {
        ensure(self.len() != 0, EVMError::StackUnderflow)?;

        self.len -= 1;
        let item = self.items.get(self.len().into());
        Result::Ok(item.deref())
    }

    /// Calls `Stack::pop` and tries to convert it to usize
    ///
    /// # Errors
    ///
    /// Returns `EVMError::StackError` with appropriate message
    /// In case:
    ///     - Stack is empty
    ///     - Type conversion failed
    #[inline(always)]
    fn pop_usize(ref self: Stack) -> Result<usize, EVMError> {
        let item: u256 = self.pop()?;
        let item: usize = item.try_into_result()?;
        Result::Ok(item)
    }

    /// Calls `Stack::pop` and tries to convert it to u64
    ///
    /// # Errors
    ///
    /// Returns `EVMError::StackError` with appropriate message
    /// In case:
    ///     - Stack is empty
    ///     - Type conversion failed
    #[inline(always)]
    fn pop_u64(ref self: Stack) -> Result<u64, EVMError> {
        let item: u256 = self.pop()?;
        let item: u64 = item.try_into_result()?;
        Result::Ok(item)
    }

    /// Calls `Stack::pop` and convert it to i256
    ///
    /// # Errors
    ///
    /// Returns `EVMError::StackError` with appropriate message
    /// In case:
    ///     - Stack is empty
    #[inline(always)]
    fn pop_i256(ref self: Stack) -> Result<i256, EVMError> {
        let item: u256 = self.pop()?;
        let item: i256 = item.into();
        Result::Ok(item)
    }


    /// Calls `Stack::pop` and tries to convert it to u128
    ///
    /// # Errors
    ///
    /// Returns `EVMError::StackError` with appropriate message
    /// In case:
    ///     - Stack is empty
    ///     - Type conversion failed
    #[inline(always)]
    fn pop_u128(ref self: Stack) -> Result<u128, EVMError> {
        let item: u256 = self.pop()?;
        let item: u128 = item.try_into_result()?;
        Result::Ok(item)
    }

    /// Calls `Stack::pop` and saturates the result to u128
    ///
    #[inline(always)]
    fn pop_saturating_u128(ref self: Stack) -> Result<u128, EVMError> {
        let item: u256 = self.pop()?;
        if item.high != 0 {
            return Result::Ok(Bounded::<u128>::MAX);
        };
        Result::Ok(item.low)
    }

    /// Calls `Stack::pop` and converts it to usize
    ///
    /// # Errors
    ///
    /// Returns `EVMError::StackError` with appropriate message
    /// In case:
    ///     - Stack is empty
    #[inline(always)]
    fn pop_eth_address(ref self: Stack) -> Result<EthAddress, EVMError> {
        let item: u256 = self.pop()?;
        let item: EthAddress = item.into();
        Result::Ok(item)
    }

    /// Pops N elements from the stack.
    ///
    /// # Errors
    ///
    /// If the stack length is less than than N, returns with a StackUnderflow error.
    fn pop_n(ref self: Stack, mut n: usize) -> Result<Array<u256>, EVMError> {
        ensure(!(n > self.len()), EVMError::StackUnderflow)?;
        let mut popped_items = ArrayTrait::<u256>::new();
        while n != 0 {
            popped_items.append(self.pop().unwrap());
            n -= 1;
        };
        Result::Ok(popped_items)
    }

    /// Peeks at the top item on the stack.
    ///
    /// # Errors
    ///
    /// If the stack is empty, returns None.
    #[inline(always)]
    fn peek(ref self: Stack) -> Option<u256> {
        if self.len() == 0 {
            Option::None(())
        } else {
            let last_index = self.len() - 1;
            let item = self.items.get(last_index.into());
            Option::Some(item.deref())
        }
    }

    /// Peeks at the item at the given index on the stack.
    /// index is 0-based, 0 being the top of the stack.
    ///
    /// # Errors
    ///
    /// If the index is greater than the stack length, returns with a StackUnderflow error.
    #[inline(always)]
    fn peek_at(ref self: Stack, index: usize) -> Result<u256, EVMError> {
        ensure(index < self.len(), EVMError::StackUnderflow)?;

        let position = self.len() - 1 - index;
        let item = self.items.get(position.into());

        Result::Ok(item.deref())
    }

    /// Swaps the item at the given index with the item on top of the stack.
    /// index is 0-based, 0 being the top of the stack (unallocated).
    #[inline(always)]
    fn swap_i(ref self: Stack, index: usize) -> Result<(), EVMError> {
        ensure(index < self.len(), EVMError::StackUnderflow)?;

        let position_0: felt252 = self.len().into() - 1;
        let position_item: felt252 = position_0 - index.into();
        let top_item = self.items.get(position_0);
        let swapped_item = self.items.get(position_item);
        self.items.insert(position_0, swapped_item.into());
        self.items.insert(position_item, top_item.into());
        Result::Ok(())
    }

    /// Returns the length of the stack.
    #[inline(always)]
    fn len(self: @Stack) -> usize {
        *self.len
    }

    /// Returns true if the stack is empty.
    #[inline(always)]
    fn is_empty(self: @Stack) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    // Core lib imports

    // Internal imports
    use evm::stack::StackTrait;
    use utils::constants;

    #[test]
    fn test_stack_new_should_return_empty_stack() {
        // When
        let mut stack = StackTrait::new();

        // Then
        assert_eq!(stack.len(), 0);
    }

    #[test]
    fn test_empty_should_return_if_stack_is_empty() {
        // Given
        let mut stack = StackTrait::new();

        // Then
        assert!(stack.is_empty());

        // When
        stack.push(1).unwrap();
        // Then
        assert!(!stack.is_empty());
    }

    #[test]
    fn test_len_should_return_the_length_of_the_stack() {
        // Given
        let mut stack = StackTrait::new();

        // Then
        assert_eq!(stack.len(), 0);

        // When
        stack.push(1).unwrap();
        // Then
        assert_eq!(stack.len(), 1);
    }

    mod push {
        use evm::errors::{EVMError};
        use super::StackTrait;

        use super::constants;

        #[test]
        fn test_should_add_an_element_to_the_stack() {
            // Given
            let mut stack = StackTrait::new();

            // When
            stack.push(1).unwrap();

            // Then
            let res = stack.peek().unwrap();

            assert_eq!(stack.is_empty(), false);
            assert_eq!(stack.len(), 1);
            assert_eq!(res, 1);
        }

        #[test]
        fn test_should_fail_when_overflow() {
            // Given
            let mut stack = StackTrait::new();
            let mut i = 0;

            // When
            while i != constants::STACK_MAX_DEPTH {
                i += 1;
                stack.push(1).unwrap();
            };

            // Then
            let res = stack.push(1);
            assert_eq!(stack.len(), constants::STACK_MAX_DEPTH);
            assert!(res.is_err());
            assert_eq!(res.unwrap_err(), EVMError::StackOverflow);
        }
    }

    mod pop {
        use core::num::traits::Bounded;
        use core::starknet::storage_base_address_const;
        use evm::errors::{EVMError, TYPE_CONVERSION_ERROR};
        use super::StackTrait;
        use utils::traits::StorageBaseAddressPartialEq;

        #[test]
        fn test_should_pop_an_element_from_the_stack() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();
            stack.push(2).unwrap();
            stack.push(3).unwrap();

            // When
            let last_item = stack.pop().unwrap();

            // Then
            assert_eq!(last_item, 3);
            assert_eq!(stack.len(), 2);
        }


        #[test]
        fn test_should_pop_N_elements_from_the_stack() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();
            stack.push(2).unwrap();
            stack.push(3).unwrap();

            // When
            let elements = stack.pop_n(3).unwrap();

            // Then
            assert_eq!(stack.len(), 0);
            assert_eq!(elements.len(), 3);
            assert_eq!(elements.span(), [3, 2, 1].span())
        }


        #[test]
        fn test_pop_return_err_when_stack_underflow() {
            // Given
            let mut stack = StackTrait::new();

            // When & Then
            let result = stack.pop();
            assert(result.is_err(), 'should return Err ');
            assert!(
                result.unwrap_err() == EVMError::StackUnderflow, "should return StackUnderflow"
            );
        }

        #[test]
        fn test_pop_n_should_return_err_when_stack_underflow() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();

            // When & Then
            let result = stack.pop_n(2);
            assert(result.is_err(), 'should return Error');
            assert!(
                result.unwrap_err() == EVMError::StackUnderflow, "should return StackUnderflow"
            );
        }


        #[test]
        fn test_pop_saturating_u128_should_return_max_when_overflow() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(Bounded::<u256>::MAX).unwrap();

            // When
            let result = stack.pop_saturating_u128();

            // Then
            assert!(result.is_ok());
            assert_eq!(result.unwrap(), Bounded::<u128>::MAX);
        }

        #[test]
        fn test_pop_saturating_u128_should_return_value_when_no_overflow() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1234567890).unwrap();

            // When
            let result = stack.pop_saturating_u128();

            // Then
            assert!(result.is_ok());
            assert_eq!(result.unwrap(), 1234567890);
        }
    }

    mod peek {
        use evm::errors::{EVMError};
        use super::StackTrait;

        #[test]
        fn test_should_return_last_item() {
            // Given
            let mut stack = StackTrait::new();

            // When
            stack.push(1).unwrap();
            stack.push(2).unwrap();

            // Then
            let last_item = stack.peek().unwrap();
            assert_eq!(last_item, 2);
        }


        #[test]
        fn test_should_return_stack_at_given_index_when_value_is_0() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();
            stack.push(2).unwrap();
            stack.push(3).unwrap();

            // When
            let result = stack.peek_at(0).unwrap();

            // Then
            assert_eq!(result, 3);
        }

        #[test]
        fn test_should_return_stack_at_given_index_when_value_is_1() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();
            stack.push(2).unwrap();
            stack.push(3).unwrap();

            // When
            let result = stack.peek_at(1).unwrap();

            // Then
            assert_eq!(result, 2);
        }

        #[test]
        fn test_should_return_err_when_underflow() {
            // Given
            let mut stack = StackTrait::new();

            // When & Then
            let result = stack.peek_at(1);

            assert(result.is_err(), 'should return an EVMError');
            assert!(
                result.unwrap_err() == EVMError::StackUnderflow, "should return StackUnderflow"
            );
        }
    }

    mod swap {
        use evm::errors::{EVMError};
        use super::StackTrait;

        #[test]
        fn test_should_swap_2_stack_items() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();
            stack.push(2).unwrap();
            stack.push(3).unwrap();
            stack.push(4).unwrap();
            let index3 = stack.peek_at(3).unwrap();
            assert_eq!(index3, 1);
            let index2 = stack.peek_at(2).unwrap();
            assert_eq!(index2, 2);
            let index1 = stack.peek_at(1).unwrap();
            assert_eq!(index1, 3);
            let index0 = stack.peek_at(0).unwrap();
            assert_eq!(index0, 4);

            // When
            stack.swap_i(2).expect('swap failed');

            // Then
            let index3 = stack.peek_at(3).unwrap();
            assert_eq!(index3, 1);
            let index2 = stack.peek_at(2).unwrap();
            assert_eq!(index2, 4);
            let index1 = stack.peek_at(1).unwrap();
            assert_eq!(index1, 3);
            let index0 = stack.peek_at(0).unwrap();
            assert_eq!(index0, 2);
        }

        #[test]
        fn test_should_return_err_when_index_1_is_underflow() {
            // Given
            let mut stack = StackTrait::new();

            // When & Then
            let result = stack.swap_i(1);

            assert!(result.is_err());
            assert_eq!(result.unwrap_err(), EVMError::StackUnderflow);
        }

        #[test]
        fn test_should_return_err_when_index_2_is_underflow() {
            // Given
            let mut stack = StackTrait::new();
            stack.push(1).unwrap();

            // When & Then
            let result = stack.swap_i(2);

            assert!(result.is_err());
            assert_eq!(result.unwrap_err(), EVMError::StackUnderflow);
        }
    }
}
