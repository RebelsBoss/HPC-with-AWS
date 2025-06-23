#!/bin/bash
set -e

PATH=/sbin:/bin:/usr/sbin:/usr/bin

echo "Started ${0} at $(date)"

yum install -y amazon-ec2-utils lsof iputils jq >/dev/null 2>&1 || true

# --- Lustre version check (optional) ---
lfs_version="$(lfs --version 2>/dev/null | awk '{print $2}')"
if [[ -z "$lfs_version" ]]; then
    echo "Warning: Lustre client not found. Skipping lfs version check."
else
    # Extract major.minor version
    major_minor=$(echo "$lfs_version" | cut -d. -f1-2)
    if [[ $(echo -e "$major_minor\n2.15" | sort -V | head -n1) != "2.15" ]]; then
        echo "Warning: Lustre client version $lfs_version is lower than 2.15"
    else
        echo "Lustre version $lfs_version is OK"
    fi
fi

# --- EFA version check ---
efa_version=$(modinfo efa 2>/dev/null | awk '/^version:/ {print $2}' | sed 's/[^0-9.]//g')
min_efa_version="2.12.1"

if [[ -z "$efa_version" ]]; then
    echo "Error: EFA driver not found"
    exit 1
fi

if [[ "$(printf '%s\n' "$min_efa_version" "$efa_version" | sort -V | head -n1)" != "$min_efa_version" ]]; then
    echo "Error: EFA driver version $efa_version does not meet minimum requirement $min_efa_version"
    exit 1
else
    echo "Using EFA driver version $efa_version"
fi

# --- Detect primary network interface ---
eth_intf="$(ip -br -4 a sh | grep $(hostname -i)/ | awk '{print $1}')"
echo "Primary eth interface: $eth_intf"

# --- Load Lustre/EFA kernel modules ---
echo "Loading Lustre/EFA modules..."
modprobe lnet || true
modprobe kefalnd ipif_name="$eth_intf" || true
modprobe ksocklnd || true
lnetctl lnet configure || true

# --- Configure TCP network ---
echo "Configuring TCP interface..."
lnetctl net del --net tcp 2>/dev/null || true
lnetctl net add --net tcp --if "$eth_intf" || true

# --- Configure EFA interfaces ---
instance_type="$(ec2-metadata --instance-type | awk '{ print $2 }')"
num_efa_devices=$(ls -1 /sys/class/infiniband 2>/dev/null | wc -l)
echo "Found $num_efa_devices EFA device(s) on $instance_type"

echo "Configuring EFA interface(s)..."
if [[ "$instance_type" == "p5.48xlarge" || "$instance_type" == "p5e.48xlarge" ]]; then
    for intf in $(ls -1 /sys/class/infiniband | awk 'NR % 4 == 1'); do
        lnetctl net add --net efa --if "$intf" --peer-credits 32 || true
    done
else
    # Default: add 1-2 EFA devices if present
    first=$(ls -1 /sys/class/infiniband | head -n1)
    last=$(ls -1 /sys/class/infiniband | tail -n1)
    lnetctl net add --net efa --if "$first" --peer-credits 32 || true
    if [[ "$first" != "$last" ]]; then
        lnetctl net add --net efa --if "$last" --peer-credits 32 || true
    fi
fi

# --- Enable discovery and UDSP ---
echo "Setting discovery and UDSP rule..."
lnetctl set discovery 1 || true
lnetctl udsp add --src efa --priority 0 || true
modprobe lustre || true

echo "Configured EFA interfaces:"
lnetctl net show
echo "Total EFA interfaces added: $(lnetctl net show | grep -c '@efa')"
