# MultiAddrs

Minimal sub-accounts that behave like EOAs—controlled by a single master address.

## Problem

You need multiple Ethereum addresses but don't want to manage multiple private keys. Existing solutions (Safe, ERC-4337) are powerful but heavyweight—they solve account abstraction, not the simpler problem of "I need more addresses."

## Solution

**MultiAddrs** deploys ultra-minimal **91-byte** sub-accounts. Each sub-account:

- **Behaves like an EOA**: Can hold ETH, call any contract, receive tokens
- **Controlled by one master**: Only the master can execute transactions
- **Zero storage**: No state, no admin, no upgrades—just raw bytecode
- **Deterministic addresses**: Know the address before deployment

```
┌─────────────────┐        ┌──────────────────┐
│  Master (EOA)   │───────▶│  SubAccount #1   │───▶ DeFi protocols
│  1 private key  │        │  SubAccount #2   │───▶ NFT mints  
│                 │        │  SubAccount #N   │───▶ Airdrops, etc.
└─────────────────┘        └──────────────────┘
         │
         └── Full control over all sub-accounts
```

## Use Cases

**For Users:**
- Separate DeFi positions without managing multiple keys
- Claim airdrops from multiple addresses
- Privacy through address separation

**For Protocols:**
- Set a **wrapper contract as master** to extend functionality
- Add batching, permissions, spending limits—whatever you need
- Users get isolated sub-accounts with protocol-specific features

**Routers & Batching:**
- External routers can batch operations across multiple sub-accounts
- Master signs once, router executes many

## How It Works

### Calldata Format

When the master calls a sub-account with ≥64 bytes:

```
[target: 32 bytes][value: 32 bytes][data: remaining bytes]
```

The sub-account executes: `target.call{value: value}(data)`

### Behavior Matrix

| Caller | Calldata | Behavior |
|--------|----------|----------|
| Master | ≥64 bytes | Execute call, return result |
| Master | <64 bytes | Accept ETH, return empty |
| Anyone else | Any | Accept ETH, return empty |

Non-masters can deposit ETH but cannot trigger any execution.

## Usage

```solidity
ISubAccountFactory factory = ISubAccountFactory(FACTORY_ADDRESS);

// Deploy a sub-account
address subAccount = factory.deploySubAccount();

// Predict address before deployment
address predicted = factory.getAccount(msg.sender, 1);

// Execute from sub-account (as master)
bytes memory callData = abi.encode(targetAddress, ethValue);
callData = bytes.concat(callData, targetCalldata);
(bool ok, bytes memory ret) = subAccount.call(callData);

// Check deployment status
uint count = factory.getAccountsCount(msg.sender);
bool exists = factory.isAccountDeployed(msg.sender, 1);
```

## Protocol Integration

Protocols can create wrappers that act as the master:

```solidity
contract ProtocolWrapper {
    ISubAccountFactory factory;
    
    // Deploy sub-account owned by this wrapper
    function createUserAccount() external returns (address) {
        return factory.deploySubAccount();
    }
    
    // Add protocol-specific logic (batching, limits, etc.)
    function executeOnBehalf(address subAccount, Call[] calldata calls) external {
        for (uint i = 0; i < calls.length; i++) {
            bytes memory payload = abi.encode(calls[i].target, calls[i].value);
            payload = bytes.concat(payload, calls[i].data);
            (bool ok,) = subAccount.call(payload);
            require(ok);
        }
    }
}
```

## Install

```bash
forge install
```

## Test

```bash
forge test
```

## Security

- **Immutable master**: Embedded in bytecode at deploy time, cannot be changed
- **No storage**: Nothing to exploit via storage manipulation
- **No admin**: No owner, no upgrades, no backdoors
- **Revert propagation**: Failed calls revert (but revert data not forwarded for gas efficiency)

## License

UNLICENSED
