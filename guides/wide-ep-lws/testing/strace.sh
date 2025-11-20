# strace -o strace.log -e trace=read,write,ioctl -s 65536 -P /dev/infiniband/uverbs0 binary

# You should see a bunch of ioctls, please check the return code and see if there are EINVAL, EOPNOTSUPP etc. If not, maybe do an A/B comparison.
# I think we did microbenchmark with 3.3.20 but not 100% certain

#!/bin/bash

# ---
# A script to find all processes using a specific Infiniband device and trace
# their read(), write(), and ioctl() system calls using strace.
# ---

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# The device we are interested in. We will filter lsof output for this.
DEVICE_PATH="/dev/infiniband/uverbs0"

# --- Main Script Logic ---

# Ensure the script is run as root, as strace and lsof need elevated privileges.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root or with sudo."
    exit 1
fi

echo "--> Step 1: Searching for processes using '$DEVICE_PATH'..."

# Find PIDs using lsof. The '-t' flag outputs only PIDs.
# We suppress errors in case no process is using the file.
PIDS=$(lsof -t "$DEVICE_PATH" 2>/dev/null || true)

if [ -z "$PIDS" ]; then
    echo "Error: No process is currently using '$DEVICE_PATH'."
    echo "Please ensure your workload is running and has opened the device."
    exit 1
fi

# Convert the newline-separated list of PIDs from lsof to a
# comma-separated list that strace can accept.
TARGET_PIDS=$(echo "$PIDS" | tr '\n' ',' | sed 's/,$//')

echo "--> Success! Found processes using device with PIDs: $TARGET_PIDS"
echo

# --- Run strace ---

LOG_FILE="/tmp/infiniband_trace_$(date +%Y%m%d_%H%M%S).log"

echo "--> Step 2: Starting strace. Logging to: $LOG_FILE"
echo "    Press Ctrl+C to stop tracing."
echo

# Execute strace with the specified filters.
# -p: Attach to the target PID(s).
# -e: Trace only the specified system calls.
# -o: Write output to the specified log file.
# -s: Set the max string size to print to avoid truncation.
# -T: Show the time spent in each system call.
# -f: Follow any child processes forked by the workload.
strace -p "$TARGET_PIDS" \
       -e trace=read,write,ioctl \
       -o "$LOG_FILE" \
       -s 2048 \
       -T \
       -f

echo
echo "--> Tracing stopped."
echo "--> Log file saved at: $LOG_FILE"

