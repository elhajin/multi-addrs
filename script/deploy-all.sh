#!/usr/bin/env bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Chain configurations: name|rpc_url|chain_id
CHAINS=(
    "Ethereum|https://ethereum-rpc.publicnode.com|1"
    "Arbitrum|https://arbitrum-one-rpc.publicnode.com|42161"
    "Optimism|https://optimism-rpc.publicnode.com|10"
    "Base|https://base-rpc.publicnode.com|8453"
    "Polygon|https://polygon-bor-rpc.publicnode.com|137"
    "BSC|https://bsc-rpc.publicnode.com|56"
    "Avalanche|https://avalanche-c-chain-rpc.publicnode.com|43114"
    "Gnosis|https://gnosis-rpc.publicnode.com|100"
    "Sepolia|https://ethereum-sepolia-rpc.publicnode.com|11155111"
    "Hoodi|https://ethereum-hoodi-rpc.publicnode.com|560048"
)

usage() {
    echo "Usage: $0 [--dry|--prod] [--chains <chain1,chain2,...>]"
    echo ""
    echo "Options:"
    echo "  --dry   Dry run - predict addresses without deploying (default)"
    echo "  --prod  Production - deploy to chains (requires PRIVATE_KEY env var)"
    echo "  --chains Comma-separated list of chains to deploy to (e.g., Ethereum,Arbitrum)"
    echo ""
    echo "Available chains: ${CHAINS[*]%%|*}"
    exit 1
}

# Parse arguments
MODE="dry"
SELECTED_CHAINS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry)
            MODE="dry"
            shift
            ;;
        --prod)
            MODE="prod"
            shift
            ;;
        --chains)
            SELECTED_CHAINS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check for PRIVATE_KEY in prod mode
if [[ "$MODE" == "prod" ]]; then
    if [[ -z "$PRIVATE_KEY" ]]; then
        echo -e "${RED}Error: PRIVATE_KEY environment variable not set${NC}"
        echo "Export it with: export PRIVATE_KEY=0x..."
        exit 1
    fi
    BROADCAST_FLAGS="--broadcast --private-key $PRIVATE_KEY"
else
    BROADCAST_FLAGS=""
fi

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         SubAccountFactory Multi-Chain Deployment           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Mode: ${YELLOW}$MODE${NC}"
echo ""

# Track results
declare -A RESULTS
declare -A ADDRESSES
FIRST_ADDRESS=""
ALL_MATCH=true

# Filter chains if --chains specified
filter_chain() {
    local name=$1
    if [[ -z "$SELECTED_CHAINS" ]]; then
        return 0  # No filter, include all
    fi
    if [[ ",$SELECTED_CHAINS," == *",$name,"* ]]; then
        return 0  # Chain is in the list
    fi
    return 1  # Chain not in list
}

# Run deployment for each chain
for chain_config in "${CHAINS[@]}"; do
    IFS='|' read -r name rpc chain_id <<< "$chain_config"
    
    # Skip if not in selected chains
    if ! filter_chain "$name"; then
        continue
    fi
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Chain: ${YELLOW}$name${NC} (ID: $chain_id)"
    echo -e "RPC:   $rpc"
    echo ""
    
    # Run forge script and capture output
    OUTPUT=$(forge script script/Deploy.s.sol --rpc-url "$rpc" $BROADCAST_FLAGS 2>&1) || {
        echo -e "${RED}✗ Failed${NC}"
        echo "$OUTPUT" | tail -5
        RESULTS[$name]="FAILED"
        continue
    }
    
    # Extract predicted address from output
    PREDICTED=$(echo "$OUTPUT" | grep -oE "Predicted:\s+0x[a-fA-F0-9]{40}" | grep -oE "0x[a-fA-F0-9]{40}" | head -1)
    STATUS=$(echo "$OUTPUT" | grep -oE "Status:\s+[A-Z_ ]+" | sed 's/Status:\s*//' | head -1)
    
    if [[ -z "$PREDICTED" ]]; then
        echo -e "${RED}✗ Could not parse address${NC}"
        echo "$OUTPUT" | tail -10
        RESULTS[$name]="PARSE_ERROR"
        continue
    fi
    
    ADDRESSES[$name]=$PREDICTED
    
    # Track first address for comparison
    if [[ -z "$FIRST_ADDRESS" ]]; then
        FIRST_ADDRESS=$PREDICTED
    fi
    
    # Check if address matches
    if [[ "$PREDICTED" == "$FIRST_ADDRESS" ]]; then
        echo -e "${GREEN}✓${NC} Address: $PREDICTED"
        echo -e "  Status: $STATUS"
        RESULTS[$name]="OK"
    else
        echo -e "${RED}✗${NC} Address: $PREDICTED (MISMATCH!)"
        echo -e "  Expected: $FIRST_ADDRESS"
        RESULTS[$name]="MISMATCH"
        ALL_MATCH=false
    fi
    echo ""
done

# Summary
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                         Summary                            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -n "$FIRST_ADDRESS" ]]; then
    echo -e "Factory Address: ${GREEN}$FIRST_ADDRESS${NC}"
    echo ""
fi

echo "Results:"
for chain_config in "${CHAINS[@]}"; do
    IFS='|' read -r name rpc chain_id <<< "$chain_config"
    if ! filter_chain "$name"; then
        continue
    fi
    
    result=${RESULTS[$name]:-"SKIPPED"}
    case $result in
        "OK")
            echo -e "  ${GREEN}✓${NC} $name"
            ;;
        "FAILED")
            echo -e "  ${RED}✗${NC} $name (failed)"
            ;;
        "MISMATCH")
            echo -e "  ${RED}✗${NC} $name (address mismatch)"
            ;;
        "PARSE_ERROR")
            echo -e "  ${YELLOW}?${NC} $name (parse error)"
            ;;
        *)
            echo -e "  ${YELLOW}-${NC} $name (skipped)"
            ;;
    esac
done

echo ""

if $ALL_MATCH && [[ -n "$FIRST_ADDRESS" ]]; then
    echo -e "${GREEN}All addresses match! Deployment is deterministic.${NC}"
    exit 0
else
    echo -e "${RED}Warning: Some addresses don't match or deployments failed.${NC}"
    exit 1
fi

