#!/bin/bash
#SBATCH --job-name=stress-full-load
#SBATCH --nodes=3 # 3 nodes (2 static + 1 dinamic)
#SBATCH --ntasks-per-node=36 # c5n.18xlarge (72 vCPU / 2 = 36)
#SBATCH --time=00:03:00 # 3 minutes on execute
#SBATCH --output=/fsx/stress_full_load.out
#SBATCH --error=/fsx/stress_full_load.err

# Info (in file .out)
echo "--- Job Start ---"
echo "Job is running on: $(hostname)"
echo "Current working directory: $(pwd)"
echo "SLURM_NNODES: $SLURM_NNODES"
echo "SLURM_NTASKS_PER_NODE: $SLURM_NTASKS_PER_NODE"
echo "Total SLURM_NTASKS: $SLURM_NTASKS"
echo "--- Starting stress-ng ---"

# Start stress-ng on all 108 cores (3 nodes * 36 cores/nodes)
# Full path to stress-ng
/usr/bin/stress-ng --cpu $SLURM_NTASKS --timeout 150 --metrics --perf --log-brief

echo "--- stress-ng finished ---"