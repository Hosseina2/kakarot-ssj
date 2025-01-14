use MockContractUpgradeableV0::HasComponentImpl_upgradeable_component;
use contracts::components::upgradeable::{IUpgradeableDispatcher, IUpgradeableDispatcherTrait};
use contracts::components::upgradeable::{upgradeable_component};
use core::serde::Serde;
use core::starknet::{deploy_syscall, ClassHash, ContractAddress, testing};

use upgradeable_component::{UpgradeableImpl};

#[starknet::interface]
trait IMockContractUpgradeable<TContractState> {
    fn version(self: @TContractState) -> felt252;
}

#[starknet::contract]
mod MockContractUpgradeableV0 {
    use contracts::components::upgradeable::{upgradeable_component};
    use super::IMockContractUpgradeable;
    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl UpgradeableImpl = upgradeable_component::Upgradeable<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        UpgradeableEvent: upgradeable_component::Event
    }

    #[abi(embed_v0)]
    impl MockContractUpgradeableImpl of IMockContractUpgradeable<ContractState> {
        fn version(self: @ContractState) -> felt252 {
            0
        }
    }
}

#[starknet::contract]
mod MockContractUpgradeableV1 {
    use contracts::components::upgradeable::{upgradeable_component};
    use super::IMockContractUpgradeable;
    component!(path: upgradeable_component, storage: upgradeable, event: upgradeableEvent);

    #[storage]
    struct Storage {
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        upgradeableEvent: upgradeable_component::Event
    }

    #[abi(embed_v0)]
    impl MockContractUpgradeableImpl of IMockContractUpgradeable<ContractState> {
        fn version(self: @ContractState) -> felt252 {
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use snforge_std::{declare, DeclareResultTrait};
    use starknet::{deploy_syscall, ClassHash};
    use super::{
        IMockContractUpgradeableDispatcher, IUpgradeableDispatcher, IUpgradeableDispatcherTrait,
        IMockContractUpgradeableDispatcherTrait
    };

    #[test]
    fn test_upgradeable_update_contract() {
        let mock_contract_upgradeable_v0_class_hash = (*declare("MockContractUpgradeableV0")
            .unwrap()
            .contract_class()
            .class_hash);
        let (contract_address, _) = deploy_syscall(
            mock_contract_upgradeable_v0_class_hash, 0, [].span(), false
        )
            .unwrap();

        let version = IMockContractUpgradeableDispatcher { contract_address: contract_address }
            .version();

        assert(version == 0, 'version is not 0');

        let mock_contract_upgradeable_v1_class_hash = (*declare("MockContractUpgradeableV1")
            .unwrap()
            .contract_class()
            .class_hash);
        let new_class_hash: ClassHash = mock_contract_upgradeable_v1_class_hash;

        IUpgradeableDispatcher { contract_address: contract_address }
            .upgrade_contract(new_class_hash);

        let version = IMockContractUpgradeableDispatcher { contract_address: contract_address }
            .version();
        assert(version == 1, 'version is not 1');
    }
}
