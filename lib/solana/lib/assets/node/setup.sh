#!/bin/bash

print_usage(){
  echo "Usage: node/setup.sh <SOLANA_VERSION> <SOLANA_NODE_TYPE> <SOLANA_CLUSTER> [NODE_IDENTITY_SECRET_ARN] [VOTE_ACCOUNT_SECRET_ARN] [AUTHORIZED_WITHDRAWER_ACCOUNT_SECRET_ARN] [REGISTRATION_TRANSACTION_FUNDING_ACCOUNT_SECRET_ARN]"
  echo "Required: <SOLANA_VERSION> <SOLANA_NODE_TYPE [consensus | baserpc | extendedrpc]> <SOLANA_CLUSTER [ mainnet-beta | testnet | devnet]>"
  echo "Optional: [NODE_IDENTITY_SECRET_ARN]"
  echo "Required only for consensus nodes: [VOTE_ACCOUNT_SECRET_ARN] [AUTHORIZED_WITHDRAWER_ACCOUNT_SECRET_ARN] [REGISTRATION_TRANSACTION_FUNDING_ACCOUNT_SECRET_ARN]"
}

if [ -n "$1" ]; then
  export SOLANA_VERSION=$1
else
  echo "Error: No Solana version is provided"
  print_usage
  exit 1
fi

if [ -n "$2" ]; then
  export SOLANA_NODE_TYPE=$2
else
  echo "Error: No Solana node type is provided"
  print_usage
  exit 1
fi

if [ -n "$3" ]; then
  export SOLANA_CLUSTER=$3
else
  echo "Error: No Solana cluster is provided"
  print_usage
  exit 1
fi

if [ -n "$4" ]; then
  export NODE_IDENTITY_SECRET_ARN=$4
else
  echo "No secret ARN for node identity is provided. Will generate one."
fi

if [ -n "$5" ]; then
  export VOTE_ACCOUNT_SECRET_ARN=$5
else
  echo "No secret ARN for vote account is provided. Will generate one."
fi

if [ -n "$6" ]; then
  export AUTHORIZED_WITHDRAWER_ACCOUNT_SECRET_ARN=$6
else
  echo "No secret ARN for authorized withdrawer account is provided. Will generate one."
fi

if [ -n "$7" ]; then
  export REGISTRATION_TRANSACTION_FUNDING_ACCOUNT_SECRET_ARN=$7
else
  if [ "$SOLANA_NODE_TYPE" == "consensus" ]; then
    echo "Error: No secret ARN for registration transaction funding account is provided."
    print_usage
    exit 1
  fi
fi

echo "Fine tune sysctl to prepare the system for Solana"
bash -c "cat >/etc/sysctl.d/20-solana-additionals.conf <<EOF
kernel.hung_task_timeout_secs=600
vm.stat_interval=10
vm.dirty_ratio=40
vm.dirty_background_ratio=10
vm.dirty_expire_centisecs=36000
vm.dirty_writeback_centisecs=3000
vm.dirtytime_expire_seconds=43200
kernel.timer_migration=0
kernel.pid_max=65536
net.ipv4.tcp_fastopen=3
fs.nr_open = 1000000
EOF"

bash -c "cat >/etc/sysctl.d/20-solana-mmaps.conf <<EOF
# Increase memory mapped files limit
vm.max_map_count = 1000000
EOF"

# Modify 134217728 -> 268435456
bash -c "cat >/etc/sysctl.d/20-solana-udp-buffers.conf <<EOF
# Increase UDP buffer size
net.core.rmem_default=134217728
net.core.rmem_max=134217728
net.core.wmem_default=134217728
net.core.wmem_max=134217728
EOF"

## New -----------
#vm.vfs_cache_pressure=50
bash -c "cat >/etc/sysctl.d/20-solana-swap.conf <<EOF
vm.swappiness=10
EOF"
#
#bash -c "cat >/etc/sysctl.d/20-solana-slab.conf <<EOF
#vm.min_slab_ratio=5
#vm.min_unmapped_ratio=20
#EOF"
#
#bash -c "cat >/etc/sysctl.d/20-solana-pages.conf <<EOF
#vm.nr_hugepages=8192
#EOF"
#
#bash -c "cat >/etc/sysctl.d/20-solana-netdev.conf <<EOF
#net.core.netdev_budget=3000
#net.core.netdev_budget_usecs=4000
#EOF"

# -----------

bash -c "echo 'DefaultLimitNOFILE=1000000' >> /etc/systemd/system.conf"

sysctl -p /etc/sysctl.d/20-solana-mmaps.conf
sysctl -p /etc/sysctl.d/20-solana-udp-buffers.conf
sysctl -p /etc/sysctl.d/20-solana-additionals.conf

# New -----------
sysctl -p /etc/sysctl.d/20-solana-swap.conf
#sysctl -p /etc/sysctl.d/20-solana-slab.conf
#sysctl -p /etc/sysctl.d/20-solana-pages.conf
#sysctl -p /etc/sysctl.d/20-solana-netdev.conf

# -----------

bash -c "cat >/etc/security/limits.d/90-solana-nofiles.conf <<EOF
# Increase process file descriptor count limit
* - nofile 1000000
EOF"

echo "Build binaries for version v$SOLANA_VERSION"
/opt/node/build-binaries.sh $SOLANA_VERSION
# continue only if the previous script has finished
if [ "$?" == 0 ]; then
  echo "Build successful"
else
  echo "Build failed"
fi

echo "Preparing node start script"

cd /home/bcuser/bin

if [[ $NODE_IDENTITY_SECRET_ARN == "none" ]]; then
    echo "Create node identity"
    ./solana-keygen new --no-passphrase -o /home/bcuser/config/validator-keypair.json
else
    echo "Get node identity from AWS Secrets Manager"
    aws secretsmanager get-secret-value --secret-id $NODE_IDENTITY_SECRET_ARN --query SecretString --output text --region $AWS_REGION > ~/validator-keypair.json
    mv ~/validator-keypair.json /home/bcuser/config/validator-keypair.json
fi
if [[ "$SOLANA_NODE_TYPE" == "consensus" ]]; then
    if [[ $NODE_IDENTITY_SECRET_ARN == "none" ]]; then
        echo "Store node identity to AWS Secrets Manager"
        NODE_IDENTITY=$(./solana-keygen pubkey /home/bcuser/config/vote-account-keypair.json)
        aws secretsmanager create-secret --name "solana-node/"$NODE_IDENTITY --description "Solana Node Identity Secret created for stack $CF_STACK_NAME" --secret-string file:///home/bcuser/config/validator-keypair.json --region $AWS_REGION
    fi
    if [[ $VOTE_ACCOUNT_SECRET_ARN == "none" ]]; then
        echo "Create Vote Account Secret"
        ./solana-keygen new --no-passphrase -o /home/bcuser/config/vote-account-keypair.json
        NODE_IDENTITY=$(./solana-keygen pubkey /home/bcuser/config/vote-account-keypair.json)
        echo "Store Vote Account Secret to AWS Secrets Manager"
        aws secretsmanager create-secret --name "solana-node/"$NODE_IDENTITY --description "Solana Vote Account Secret created for stack $CF_STACK_NAME" --secret-string file:///home/bcuser/config/vote-account-keypair.json --region $AWS_REGION
        if [[ $AUTHORIZED_WITHDRAWER_ACCOUNT_SECRET_ARN == "none" ]]; then
            echo "Create Authorized Withdrawer Account Secret"
            ./solana-keygen new --no-passphrase -o /home/bcuser/config/authorized-withdrawer-keypair.json
            NODE_IDENTITY=$(./solana-keygen pubkey /home/bcuser/config/authorized-withdrawer-keypair.json)
            echo "Store Authorized Withdrawer Account  to AWS Secrets Manager"
            aws secretsmanager create-secret --name "solana-node/"$NODE_IDENTITY --description "Authorized Withdrawer Account Secret created for stack $CF_STACK_NAME" --secret-string file:///home/bcuser/config/authorized-withdrawer-keypair.json --region $AWS_REGION
        else
            echo "Get Authorized Withdrawer Account Secret from AWS Secrets Manager"
            aws secretsmanager get-secret-value --secret-id $AUTHORIZED_WITHDRAWER_ACCOUNT_SECRET_ARN --query SecretString --output text --region $AWS_REGION > ~/authorized-withdrawer-keypair.json
            mv ~/authorized-withdrawer-keypair.json /home/bcuser/config/authorized-withdrawer-keypair.json
        fi
        if [[ $REGISTRATION_TRANSACTION_FUNDING_ACCOUNT_SECRET_ARN != "none" ]]; then
          echo "Get Registration Transaction Funding Account Secret from AWS Secrets Manager"
          aws secretsmanager get-secret-value --secret-id $REGISTRATION_TRANSACTION_FUNDING_ACCOUNT_SECRET_ARN --query SecretString --output text --region $AWS_REGION > ~/id.json
          mkdir -p /root/.config/solana
          mv ~/id.json /root/.config/solana/id.json
          echo "Creating Vote Account on-chain"
          ./solana create-vote-account /home/bcuser/config/vote-account-keypair.json /home/bcuser/config/validator-keypair.json /home/bcuser/config/authorized-withdrawer-keypair.json
          echo "Delete Transaction Funding Account Secret from the local disc"
          rm  /root/.config/solana/id.json
        else
          echo "Vote Account not created. Please create it manually: https://docs.solana.com/running-validator/validator-start#create-vote-account"
        fi
        echo "Delete Authorized Withdrawer Account from the local disc"
        rm /home/bcuser/config/authorized-withdrawer-keypair.json
    else
        echo "Get Vote Account Secret from AWS Secrets Manager"
        aws secretsmanager get-secret-value --secret-id $VOTE_ACCOUNT_SECRET_ARN --query SecretString --output text --region $AWS_REGION > ~/vote-account-keypair.json
        mv ~/vote-account-keypair.json /home/bcuser/config/vote-account-keypair.json
    fi
mv /opt/node/node-consensus-template.sh /home/bcuser/bin/node-service.sh
fi

if [[ "$SOLANA_NODE_TYPE" == "baserpc" ]]; then
  mv /opt/node/node-base-rpc-template.sh /home/bcuser/bin/node-service.sh
fi

if [[ "$SOLANA_NODE_TYPE" == "extendedrpc" ]]; then
  mv /opt/node/node-extended-rpc-template.sh /home/bcuser/bin/node-service.sh
fi

case $SOLANA_CLUSTER in
  "mainnet-beta")
    ENTRY_POINTS=" --entrypoint entrypoint.mainnet-beta.solana.com:8001 --entrypoint entrypoint2.mainnet-beta.solana.com:8001 --entrypoint entrypoint3.mainnet-beta.solana.com:8001 --entrypoint entrypoint4.mainnet-beta.solana.com:8001 --entrypoint entrypoint5.mainnet-beta.solana.com:8001"
    KNOWN_VALIDATORS=" --known-validator 7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2 --known-validator GdnSyH3YtwcxFvQrVVJMm1JhTS4QVX7MFsX56uJLUfiZ --known-validator DE1bawNcRJB9rVm3buyMVfr8mBEoyyu73NBovf2oXJsJ --known-validator CakcnaRDHka2gXyfbEd2d3xsvkJkqsLw2akB3zsN1D2S"
    SOLANA_METRICS_CONFIG="host=https://metrics.solana.com:8086,db=mainnet-beta,u=mainnet-beta_write,p=password"
    EXPECTED_GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
    ;;
  "testnet")
    ENTRY_POINTS=" --entrypoint entrypoint.testnet.solana.com:8001 --entrypoint entrypoint2.testnet.solana.com:8001 --entrypoint entrypoint3.testnet.solana.com:8001"
    KNOWN_VALIDATORS=" --known-validator 5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on --known-validator dDzy5SR3AXdYWVqbDEkVFdvSPCtS9ihF5kJkHCtXoFs --known-validator Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN --known-validator eoKpUABi59aT4rR9HGS3LcMecfut9x7zJyodWWP43YQ --known-validator 9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv"
    SOLANA_METRICS_CONFIG="host=https://metrics.solana.com:8086,db=tds,u=testnet_write,p=c4fa841aa918bf8274e3e2a44d77568d9861b3ea"
    EXPECTED_GENESIS_HASH="4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"
    ;;
  "devnet")
    ENTRY_POINTS=" --entrypoint entrypoint.devnet.solana.com:8001 --entrypoint entrypoint2.devnet.solana.com:8001 --entrypoint entrypoint3.devnet.solana.com:8001 --entrypoint entrypoint4.devnet.solana.com:8001 --entrypoint entrypoint5.devnet.solana.com:8001"
    KNOWN_VALIDATORS=" --known-validator dv1ZAGvdsz5hHLwWXsVnM94hWf1pjbKVau1QVkaMJ92 --known-validator dv2eQHeP4RFrJZ6UeiZWoc3XTtmtZCUKxxCApCDcRNV --known-validator dv4ACNkpYPcE3aKmYDqZm9G5EB3J4MRoeE7WNDRBVJB --known-validator dv3qDFk1DTF36Z62bNvrCXe9sKATA6xvVy6A798xxAS"
    SOLANA_METRICS_CONFIG="host=https://metrics.solana.com:8086,db=devnet,u=scratch_writer,p=topsecret"
    EXPECTED_GENESIS_HASH="EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
    ;;
  *)
    echo "Solana cluster id is not valid: $SOLANA_CLUSTER"
    exit 1
    ;;
esac

sed -i "s;__SOLANA_METRICS_CONFIG__;\"$SOLANA_METRICS_CONFIG\";g" /home/bcuser/bin/node-service.sh
sed -i "s/__EXPECTED_GENESIS_HASH__/$EXPECTED_GENESIS_HASH/g" /home/bcuser/bin/node-service.sh
sed -i "s/__KNOWN_VALIDATORS__/$KNOWN_VALIDATORS/g" /home/bcuser/bin/node-service.sh
sed -i "s/__ENTRY_POINTS__/$ENTRY_POINTS/g" /home/bcuser/bin/node-service.sh
chmod +x /home/bcuser/bin/node-service.sh

mkdir /data/data/ledger
ln -s /data/data/ledger /home/bcuser
mkdir /data/log
chown -R bcuser:bcuser /data
chown -R bcuser:bcuser /home/bcuser

cd /home/ubuntu
wget https://go.dev/dl/go1.21.4.linux-amd64.tar.gz -O go.tar.gz
sudo tar -xzvf go.tar.gz -C /usr/local

wget -qO /usr/local/bin/websocat https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl
chmod a+x /usr/local/bin/websocat

echo "Setup Solana testing environment"

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
EC2_INTERNAL_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4)

export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH=$GOPATH/bin:$GOROOT/bin:$PATH

echo "export GOROOT=/usr/local/go" >> ~/.bashrc
echo "export GOPATH=/root/go" >> ~/.bashrc
echo "export PATH=\$GOPATH/bin:\$GOROOT/bin:\$PATH" >> ~/.bashrc

# WS & RPC
echo 'export WS_URL="ws://'${EC2_INTERNAL_IP}':8900"' >> ~/.bashrc
echo 'export RPC_URL="http://'${EC2_INTERNAL_IP}':8899"' >> ~/.bashrc

# Account to monitor
echo 'export MONITORED_ADDRESS="TSLvdd1pWpHVjahSpsvCXUbgwsL3JAcvokwaKt1eokM"' >> ~/.bashrc

# Worker configuration
echo "export WORKER_COUNT=32" >> ~/.bashrc
echo "export JOB_QUEUE_SIZE=5000" >> ~/.bashrc
echo "export MAX_RETRIES=3" >> ~/.bashrc

# Timing settings
echo "export RECONNECT_INITIAL=\"1s\"" >> ~/.bashrc
echo "export RECONNECT_MAX=\"30s\"" >> ~/.bashrc
echo "export HTTP_TIMEOUT=\"10s\"" >> ~/.bashrc
echo "export STATS_INTERVAL=\"5s\"" >> ~/.bashrc


cat << 'EOF' > checker.sh
#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

MAINNET_RPC="https://api.mainnet-beta.solana.com"
LOCAL_RPC=$RPC_URL

if ! command -v curl &> /dev/null; then
    echo "Error: need install curl"
    exit 1
fi


if ! command -v jq &> /dev/null; then
    echo "Error: need install jq"
    exit 1
fi

echo "Starting to monitor the slot differences between Solana mainnet and local RPC nodes......"
echo "Ctrl+C to exit"
echo "----------------------------------------"

while true; do

    MAINNET_SLOT=$(curl -s -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"processed"}]}' $MAINNET_RPC | jq '.result')


    LOCAL_SLOT=$(curl -s -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"processed"}]}' $LOCAL_RPC | jq '.result')


    if [[ "$MAINNET_SLOT" == "null" || -z "$MAINNET_SLOT" ]]; then
        echo -e "${RED}can't get mainnet slot info${NC}"
        MAINNET_SLOT="N/A"
    fi

    if [[ "$LOCAL_SLOT" == "null" || -z "$LOCAL_SLOT" ]]; then
        echo -e "${RED}can't get localhost slot info${NC}"
        LOCAL_SLOT="N/A"
    fi


    if [[ "$MAINNET_SLOT" != "N/A" && "$LOCAL_SLOT" != "N/A" ]]; then
        DIFF=$((MAINNET_SLOT - LOCAL_SLOT))


        if [[ $DIFF -lt 0 ]]; then
            DIFF_COLOR="${GREEN}"
            DIFF_ABS=$((DIFF * -1))
            DIFF_TEXT="Ahead"
        elif [[ $DIFF -eq 0 ]]; then
            DIFF_COLOR="${GREEN}"
            DIFF_ABS=$DIFF
            DIFF_TEXT="Synchronized"
        else
            DIFF_COLOR="${YELLOW}"
            DIFF_ABS=$DIFF
            DIFF_TEXT="Behind"
        fi

        echo -e "$(date '+%Y-%m-%d %H:%M:%S') | Mainnet: ${GREEN}$MAINNET_SLOT${NC} | Local: ${GREEN}$LOCAL_SLOT${NC} | Offset: ${DIFF_COLOR}$DIFF_TEXT $DIFF_ABS${NC}"
    else
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') | Mainnet: $MAINNET_SLOT | Local: $LOCAL_SLOT | Offset: N/A"
    fi

    sleep 1
done
EOF

chmod +x checker.sh

echo "Solana Websocket Go Program"
mkdir -p $GOPATH/src/ws-solana
cd $GOPATH/src/ws-solana
go mod init ws-solana
go get github.com/gorilla/websocket

cat << 'EOF' > ws-solana.go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ========================== Type Definitions ========================== //

// RPCRequest represents a request sent to RPC/WebSocket
type RPCRequest struct {
	JsonRPC string      `json:"jsonrpc"`
	ID      int         `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

// RPCError represents an error in RPC response
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// RPCResponse represents a generic RPC response
type RPCResponse struct {
	Jsonrpc string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result"`
	ID      int             `json:"id"`
	Error   *RPCError       `json:"error,omitempty"`
}

// LogsNotification used to parse logsNotification from WebSocket
type LogsNotification struct {
	Jsonrpc string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  struct {
		Result struct {
			Context struct {
				Slot uint64 `json:"slot"`
			} `json:"context"`
			Value struct {
				Signature string   `json:"signature"`
				Err       any      `json:"err"`
				Logs      []string `json:"logs"`
			} `json:"value"`
		} `json:"result"`
		Subscription int `json:"subscription"`
	} `json:"params"`
}

// GetTransactionResult used to parse getTransaction result
type GetTransactionResult struct {
	Slot        uint64          `json:"slot"`
	Transaction json.RawMessage `json:"transaction"`
	Meta        json.RawMessage `json:"meta"`
}

// TransactionJob represents a transaction processing task
type TransactionJob struct {
	Signature  string
	Slot       uint64
	ReceivedAt time.Time
}

// TransactionResponse represents the result of transaction processing
type TransactionResponse struct {
	Success   bool
	Latency   time.Duration
	Error     error
	Signature string
	Slot      uint64
}

// Config stores application configuration
type Config struct {
	WsURL            string
	RpcURL           string
	MonitoredAddress string
	WorkerCount      int
	JobQueueSize     int
	MaxRetries       int
	ReconnectDelay   time.Duration
	HttpTimeout      time.Duration
	PingInterval     time.Duration
	RetryDelay       time.Duration
	StatsInterval    time.Duration
}

// ========================== Constants ========================== //

const (
	ColorReset  = "\033[0m"
	ColorGreen  = "\033[32m"
	ColorYellow = "\033[33m"
	ColorRed    = "\033[31m"
	ColorPurple = "\033[35m"
	ColorBlue   = "\033[34m"

	// Constants for statistics
	RecentSamplesSize = 1000 // Size of the recent samples circular buffer
)

// ========================== CircularBuffer ========================== //

// CircularBuffer implements a fixed-size circular buffer for latency samples
type CircularBuffer struct {
	data       []time.Duration
	capacity   int
	count      int
	start      int
	totalValue time.Duration
	minValue   time.Duration
	maxValue   time.Duration
}

// NewCircularBuffer creates a new circular buffer with specified capacity
func NewCircularBuffer(capacity int) *CircularBuffer {
	return &CircularBuffer{
		data:       make([]time.Duration, capacity),
		capacity:   capacity,
		count:      0,
		start:      0,
		totalValue: 0,
		minValue:   math.MaxInt64,
		maxValue:   0,
	}
}

// Add adds a new sample to the circular buffer
func (cb *CircularBuffer) Add(value time.Duration) {
	// Calculate position to insert
	pos := (cb.start + cb.count) % cb.capacity

	// If buffer is full, remove oldest value from totals
	if cb.count == cb.capacity {
		oldValue := cb.data[cb.start]
		cb.totalValue -= oldValue

		// Update start pointer to point to next oldest item
		cb.start = (cb.start + 1) % cb.capacity
		cb.count--

		// If we're removing the min/max, we'll need to recalculate
		needRecalculateMin := (oldValue == cb.minValue)
		needRecalculateMax := (oldValue == cb.maxValue)

		// Add new value
		cb.data[pos] = value
		cb.totalValue += value
		cb.count++

		// Update min/max if needed
		if value < cb.minValue {
			cb.minValue = value
		} else if needRecalculateMin {
			// Recalculate minimum
			cb.recalculateMin()
		}

		if value > cb.maxValue {
			cb.maxValue = value
		} else if needRecalculateMax {
			// Recalculate maximum
			cb.recalculateMax()
		}
	} else {
		// Buffer not full yet, just add value
		cb.data[pos] = value
		cb.totalValue += value
		cb.count++

		// Update min/max
		if value < cb.minValue {
			cb.minValue = value
		}
		if value > cb.maxValue {
			cb.maxValue = value
		}
	}
}

// recalculateMin finds the new minimum value in the buffer
func (cb *CircularBuffer) recalculateMin() {
	if cb.count == 0 {
		cb.minValue = math.MaxInt64
		return
	}

	min := cb.data[cb.start]
	for i := 0; i < cb.count; i++ {
		idx := (cb.start + i) % cb.capacity
		if cb.data[idx] < min {
			min = cb.data[idx]
		}
	}
	cb.minValue = min
}

// recalculateMax finds the new maximum value in the buffer
func (cb *CircularBuffer) recalculateMax() {
	if cb.count == 0 {
		cb.maxValue = 0
		return
	}

	max := cb.data[cb.start]
	for i := 0; i < cb.count; i++ {
		idx := (cb.start + i) % cb.capacity
		if cb.data[idx] > max {
			max = cb.data[idx]
		}
	}
	cb.maxValue = max
}

// GetMin returns the minimum value in the buffer
func (cb *CircularBuffer) GetMin() time.Duration {
	if cb.count == 0 {
		return 0
	}
	return cb.minValue
}

// GetMax returns the maximum value in the buffer
func (cb *CircularBuffer) GetMax() time.Duration {
	if cb.count == 0 {
		return 0
	}
	return cb.maxValue
}

// GetAvg returns the average value in the buffer
func (cb *CircularBuffer) GetAvg() time.Duration {
	if cb.count == 0 {
		return 0
	}
	return cb.totalValue / time.Duration(cb.count)
}

// GetTotal returns the sum of all values in the buffer
func (cb *CircularBuffer) GetTotal() time.Duration {
	return cb.totalValue
}

// GetCount returns the number of elements currently in the buffer
func (cb *CircularBuffer) GetCount() int {
	return cb.count
}

// ToSlice returns all values in the buffer as a slice
func (cb *CircularBuffer) ToSlice() []time.Duration {
	if cb.count == 0 {
		return []time.Duration{}
	}

	result := make([]time.Duration, cb.count)
	for i := 0; i < cb.count; i++ {
		result[i] = cb.data[(cb.start+i)%cb.capacity]
	}
	return result
}

// ========================== Global Stats ========================== //

type Stats struct {
	mu                 sync.Mutex
	totalRequests      int
	successRequests    int
	processingRequests int
	failedRequests     int
	droppedRequests    int
	lastPrintTime      time.Time
	printInterval      time.Duration

	globalMinLatency time.Duration
	globalMaxLatency time.Duration
	totalLatency     time.Duration
	latencyCount     int

	// Latency percentiles
	latencyP50 time.Duration
	latencyP90 time.Duration
	latencyP99 time.Duration

	// Recent samples using circular buffer (thread-safe with mu)
	recentSamples *CircularBuffer
}

func (s *Stats) IncrementTotal() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.totalRequests++
	s.processingRequests++
	s.printStatsIfNeeded()
}

func (s *Stats) DecrementProcessing() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.processingRequests > 0 {
		s.processingRequests--
	}
}

func (s *Stats) IncrementSuccess() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.successRequests++
	s.printStatsIfNeeded()
}

func (s *Stats) IncrementFailed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failedRequests++
	s.printStatsIfNeeded()
}

func (s *Stats) IncrementDropped() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.droppedRequests++
	s.printStatsIfNeeded()
}

func (s *Stats) RecordLatency(latency time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update global statistics
	s.totalLatency += latency
	s.latencyCount++

	// Update global min/max
	if s.globalMinLatency == math.MaxInt64 || latency < s.globalMinLatency {
		s.globalMinLatency = latency
	}
	if latency > s.globalMaxLatency {
		s.globalMaxLatency = latency
	}

	// Add to recent samples circular buffer
	s.recentSamples.Add(latency)

	s.printStatsIfNeeded()
}

func (s *Stats) calculatePercentiles() {
	samples := s.recentSamples.ToSlice()
	sampleCount := len(samples)

	if sampleCount == 0 {
		return // Nothing to calculate
	}

	// Sort the samples for percentile calculation
	sort.Slice(samples, func(i, j int) bool {
		return samples[i] < samples[j]
	})

	// Calculate percentiles with boundary checks
	p50Index := int(float64(sampleCount) * 0.5)
	if p50Index >= sampleCount {
		p50Index = sampleCount - 1
	}

	p90Index := int(float64(sampleCount) * 0.9)
	if p90Index >= sampleCount {
		p90Index = sampleCount - 1
	}

	p99Index := int(float64(sampleCount) * 0.99)
	if p99Index >= sampleCount {
		p99Index = sampleCount - 1
	}

	// Set percentiles
	s.latencyP50 = samples[p50Index]
	s.latencyP90 = samples[p90Index]
	s.latencyP99 = samples[p99Index]
}

func (s *Stats) printStatsIfNeeded() {
	now := time.Now()
	if now.Sub(s.lastPrintTime) >= s.printInterval {
		// Calculate global average latency
		var globalAvgLatency time.Duration
		if s.latencyCount > 0 {
			globalAvgLatency = s.totalLatency / time.Duration(s.latencyCount)
		}

		// Calculate percentiles
		s.calculatePercentiles()

		// Get recent stats from circular buffer
		recentMinLatency := s.recentSamples.GetMin()
		recentMaxLatency := s.recentSamples.GetMax()
		recentAvgLatency := s.recentSamples.GetAvg()

		// Log statistics
		log.Printf(ColorGreen+"Stats - Total: %d, Success: %d, Processing: %d, Failed: %d, Dropped: %d"+ColorReset,
			s.totalRequests, s.successRequests, s.processingRequests, s.failedRequests, s.droppedRequests)

		log.Printf(ColorBlue+"Global Latency (µs) - Avg: %d, Min: %d, Max: %d"+ColorReset,
			globalAvgLatency.Microseconds(),
			s.globalMinLatency.Microseconds(),
			s.globalMaxLatency.Microseconds())

		log.Printf(ColorPurple+"Recent Latency (µs) - Avg: %d, Min: %d, Max: %d, P50: %d, P90: %d, P99: %d"+ColorReset,
			recentAvgLatency.Microseconds(),
			recentMinLatency.Microseconds(),
			recentMaxLatency.Microseconds(),
			s.latencyP50.Microseconds(),
			s.latencyP90.Microseconds(),
			s.latencyP99.Microseconds())

		s.lastPrintTime = now
	}
}

// ========================== Configuration Functions ========================== //

// getEnvString returns environment variable or default value
func getEnvString(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}

// getEnvInt returns environment variable as int or default value
func getEnvInt(key string, defaultValue int) int {
	if value, exists := os.LookupEnv(key); exists {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
		log.Printf("Warning: Invalid value for %s, using default: %d", key, defaultValue)
	}
	return defaultValue
}

// getEnvDuration parses environment variable as duration or returns default
func getEnvDuration(key, defaultValue string) (time.Duration, error) {
	value := getEnvString(key, defaultValue)
	return time.ParseDuration(value)
}

// loadConfig loads application configuration from environment variables
func loadConfig() (*Config, error) {
	config := &Config{}

	// URLs
	config.WsURL = getEnvString("WS_URL", "ws://127.0.0.1:8900")
	config.RpcURL = getEnvString("RPC_URL", "http://127.0.0.1:8899")

	// Account monitoring
	config.MonitoredAddress = getEnvString("MONITORED_ADDRESS", "TSLvdd1pWpHVjahSpsvCXUbgwsL3JAcvokwaKt1eokM")

	// Worker configuration
	config.WorkerCount = getEnvInt("WORKER_COUNT", 10)
	config.JobQueueSize = getEnvInt("JOB_QUEUE_SIZE", 1000)
	config.MaxRetries = getEnvInt("MAX_RETRIES", 3)

	// Timing settings
	var err error

	config.ReconnectDelay, err = getEnvDuration("RECONNECT_INITIAL", "5s")
	if err != nil {
		return nil, fmt.Errorf("failed to parse RECONNECT_INITIAL: %w", err)
	}

	config.HttpTimeout, err = getEnvDuration("HTTP_TIMEOUT", "10s")
	if err != nil {
		return nil, fmt.Errorf("failed to parse HTTP_TIMEOUT: %w", err)
	}

	config.StatsInterval, err = getEnvDuration("STATS_INTERVAL", "5s")
	if err != nil {
		return nil, fmt.Errorf("failed to parse STATS_INTERVAL: %w", err)
	}

	// Default values for other settings
	config.PingInterval = 30 * time.Second
	config.RetryDelay = 500 * time.Millisecond

	return config, nil
}

// ========================== Main Entry ========================== //

func main() {
	// Load configuration from environment variables
	config, err := loadConfig()
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize statistics with proper initial values
	stats := &Stats{
		lastPrintTime:    time.Now(),
		printInterval:    config.StatsInterval,
		globalMinLatency: math.MaxInt64, // Initialize to maximum value
		recentSamples:    NewCircularBuffer(RecentSamplesSize),
	}

	// Create global HTTP client
	httpClient := &http.Client{
		Timeout: config.HttpTimeout,
		Transport: &http.Transport{
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 100,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	// Create job queue and result channel
	jobQueue := make(chan TransactionJob, config.JobQueueSize)
	resultChan := make(chan TransactionResponse, config.JobQueueSize)

	// Start stats collector
	go statsCollector(ctx, resultChan, stats)

	// Start worker pool
	var wg sync.WaitGroup
	for i := 0; i < config.WorkerCount; i++ {
		wg.Add(1)
		go worker(ctx, i, jobQueue, resultChan, httpClient, config, &wg)
	}

	// Start WebSocket listener
	for {
		if err := startWebSocketListener(ctx, jobQueue, stats, config); err != nil {
			log.Printf("WebSocket connection lost: %v, reconnecting in %d ms...",
				err, config.ReconnectDelay.Milliseconds())
			select {
			case <-ctx.Done():
				goto cleanup
			case <-time.After(config.ReconnectDelay):
				continue
			}
		}
		break
	}

cleanup:
	// Close job queue and wait for all workers to complete
	close(jobQueue)
	wg.Wait()
	close(resultChan)
	log.Println("Program exited normally")
}

// statsCollector collects and processes transaction results
func statsCollector(ctx context.Context, results <-chan TransactionResponse, stats *Stats) {
	for {
		select {
		case <-ctx.Done():
			return
		case result, ok := <-results:
			if !ok {
				return
			}
			if result.Success {
				stats.IncrementSuccess()
				stats.DecrementProcessing()
				stats.RecordLatency(result.Latency)
				log.Printf(ColorYellow+"Transaction %s processed successfully, latency: %d µs (slot: %d)"+ColorReset,
					result.Signature, result.Latency.Microseconds(), result.Slot)
			} else {
				stats.IncrementFailed()
				stats.DecrementProcessing()
				log.Printf(ColorRed+"Transaction %s processing failed: %v"+ColorReset, result.Signature, result.Error)
			}
		}
	}
}

// ========================== WebSocket Listener ========================== //

func startWebSocketListener(ctx context.Context, jobQueue chan<- TransactionJob, stats *Stats, config *Config) error {
	// Connect to WebSocket
	log.Printf("Connecting to WebSocket: %s", config.WsURL)

	dialer := websocket.DefaultDialer
	dialer.HandshakeTimeout = 10 * time.Second

	conn, _, err := dialer.Dial(config.WsURL, nil)
	if err != nil {
		return fmt.Errorf("failed to connect to WebSocket: %w", err)
	}
	defer conn.Close()
	log.Println("Successfully connected to WebSocket")

	// Send subscription request
	subscribeMsg := RPCRequest{
		JsonRPC: "2.0",
		ID:      1,
		Method:  "logsSubscribe",
		Params: []interface{}{
			map[string]interface{}{
				"mentions": []string{config.MonitoredAddress},
			},
			map[string]interface{}{
				"commitment": "confirmed",
			},
		},
	}

	if err := conn.WriteJSON(subscribeMsg); err != nil {
		return fmt.Errorf("failed to send subscription request: %w", err)
	}
	log.Printf("Subscription request sent, monitoring account: %s", config.MonitoredAddress)

	// Wait for subscription confirmation
	_, msg, err := conn.ReadMessage()
	if err != nil {
		return fmt.Errorf("failed to read subscription confirmation: %w", err)
	}
	log.Printf("Subscription confirmed: %s", msg)

	// Set ping handler to keep connection alive
	conn.SetPingHandler(func(appData string) error {
		return conn.WriteControl(websocket.PongMessage, []byte(appData), time.Now().Add(5*time.Second))
	})

	// Set pong handler to track liveness
	lastPong := time.Now()
	conn.SetPongHandler(func(string) error {
		lastPong = time.Now()
		return nil
	})

	// Start ping sender to keep connection
	wsCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Periodically send ping
	go func() {
		ticker := time.NewTicker(config.PingInterval)
		defer ticker.Stop()

		for {
			select {
			case <-wsCtx.Done():
				return
			case <-ticker.C:
				// Check last pong time
				if time.Since(lastPong) > config.PingInterval*2 {
					log.Printf(ColorRed+"WebSocket seems disconnected, no pong received for %d ms"+ColorReset,
						(config.PingInterval * 2).Milliseconds())
					cancel() // Trigger reconnect
					return
				}

				if err := conn.WriteControl(
					websocket.PingMessage,
					[]byte{},
					time.Now().Add(5*time.Second),
				); err != nil {
					log.Printf("Failed to send ping: %v", err)
					cancel() // Trigger reconnect
					return
				}
			}
		}
	}()

	// Clear read deadline
	conn.SetReadDeadline(time.Time{})

	// Start listening for WebSocket messages
	for {
		select {
		case <-wsCtx.Done():
			return nil
		default:
			// Read message
			_, msg, err := conn.ReadMessage()
			if err != nil {
				return fmt.Errorf("error reading WebSocket message: %w", err)
			}
			// Try parsing as logsNotification
			var ln LogsNotification
			if err := json.Unmarshal(msg, &ln); err == nil && ln.Method == "logsNotification" {
				signature := ln.Params.Result.Value.Signature
				slot := ln.Params.Result.Context.Slot

				if signature != "" {
					log.Printf("Detected transaction signature: %s (slot: %d)", signature, slot)

					// Send task to job queue, record reception time
					job := TransactionJob{
						Signature:  signature,
						Slot:       slot,
						ReceivedAt: time.Now(), // Record reception time for latency calculation
					}

					select {
					case jobQueue <- job:
						stats.IncrementTotal()
					default:
						log.Printf(ColorPurple+"Warning: Job queue full, dropping transaction: %s"+ColorReset, signature)
						stats.IncrementDropped()
					}
				}
			}
		}
	}
}

// ========================== Worker Thread ========================== //

func worker(
	ctx context.Context,
	id int,
	jobs <-chan TransactionJob,
	results chan<- TransactionResponse,
	httpClient *http.Client,
	config *Config,
	wg *sync.WaitGroup,
) {
	defer wg.Done()
	log.Printf("Worker #%d started", id)

	for {
		select {
		case <-ctx.Done():
			log.Printf("Worker #%d received exit signal", id)
			return
		case job, ok := <-jobs:
			if !ok {
				log.Printf("Worker #%d job queue closed, exiting", id)
				return
			}

			log.Printf("Worker #%d processing transaction: %s", id, job.Signature)

			// Process transaction with retry
			txResult, err := getTransactionWithRetry(ctx, job.Signature, httpClient, config)

			// Calculate request latency (microsecond precision)
			latency := time.Since(job.ReceivedAt)

			// Send result
			result := TransactionResponse{
				Success:   err == nil,
				Latency:   latency,
				Error:     err,
				Signature: job.Signature,
			}

			if txResult != nil {
				result.Slot = txResult.Slot
			}

			select {
			case results <- result:
				// Result sent
			case <-ctx.Done():
				return
			}
		}
	}
}

// ========================== getTransaction RPC Call ========================== //

// getTransactionWithRetry transaction retrieval function with retry mechanism
func getTransactionWithRetry(ctx context.Context, signature string, client *http.Client, config *Config) (*GetTransactionResult, error) {
	var lastErr error

	for attempt := 0; attempt <= config.MaxRetries; attempt++ {
		if attempt > 0 {
			// Wait before retrying
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(config.RetryDelay * time.Duration(attempt)):
				// Continue retrying
			}
			log.Printf("Retrying to get transaction %s (attempt %d/%d)", signature, attempt, config.MaxRetries)
		}

		result, err := getTransaction(ctx, signature, client, config)
		if err == nil {
			return result, nil
		}

		lastErr = err
		log.Printf("Failed to get transaction: %v, will retry...", err)
	}

	return nil, fmt.Errorf("failed to get transaction after %d attempts: %w", config.MaxRetries, lastErr)
}

func getTransaction(ctx context.Context, signature string, client *http.Client, config *Config) (*GetTransactionResult, error) {
	// Create context with timeout
	reqCtx, cancel := context.WithTimeout(ctx, config.HttpTimeout)
	defer cancel()

	// Construct request body
	req := RPCRequest{
		JsonRPC: "2.0",
		ID:      1,
		Method:  "getTransaction",
		Params: []interface{}{
			signature,
			map[string]interface{}{
				"encoding":                       "jsonParsed",
				"maxSupportedTransactionVersion": 0,
			},
		},
	}

	// Serialize request
	rawBody, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to serialize RPC request: %w", err)
	}

	// Create HTTP request
	httpReq, err := http.NewRequestWithContext(reqCtx, "POST", config.RpcURL, bytes.NewBuffer(rawBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create HTTP request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	// Make HTTP request
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	// Parse response
	var rpcResp RPCResponse
	if err := json.NewDecoder(resp.Body).Decode(&rpcResp); err != nil {
		return nil, fmt.Errorf("failed to parse RPC response: %w", err)
	}

	// Check for RPC error
	if rpcResp.Error != nil {
		return nil, fmt.Errorf("RPC error response: code=%d, msg=%s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	// Parse getTransaction result
	var txRes GetTransactionResult
	if err := json.Unmarshal(rpcResp.Result, &txRes); err != nil {
		return nil, fmt.Errorf("failed to parse getTransaction result: %w", err)
	}

	return &txRes, nil
}

EOF

go mod tidy

echo "Solana configuration finished."

echo "Starting node as a service"

mv /opt/node/node.service /etc/systemd/system/node.service
systemctl daemon-reload
systemctl enable --now node
