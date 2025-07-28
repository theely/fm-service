#!/bin/bash

# Submit SGLang jobs to SLURM
#
# USAGE:
#   ./submit_sgl.sh MODEL [NUM_JOBS] [TIME_LIMIT]
#
# ARGUMENTS:
#   MODEL        Required: "qwen" or "llama"
#   NUM_JOBS     Optional: Number of jobs to submit (default: 1)
#   TIME_LIMIT   Optional: SLURM time limit in HH:MM:SS (default: 2:00:00)
#
# EXAMPLES:
#   ./submit_sgl.sh qwen                    # 1 qwen job, 2h limit
#   ./submit_sgl.sh llama 3                 # 3 llama jobs, 2h limit
#   ./submit_sgl.sh qwen 2 4:00:00          # 2 qwen jobs, 4h limit
#   ./submit_sgl.sh apertus 2 4:00:00       # 2 apertus jobs, 4h limit
#
# MODELS:
#   qwen  -> Qwen/Qwen3-32B (with reasoning/tool parsers)
#   llama -> meta-llama/Llama-3.3-70B-Instruct
#   apertus -> apertus3-70b-15T-sft

if [[ $# -eq 0 ]]; then
    head -n 20 "$0" | tail -n +3
    exit 0
fi

MODEL=$1
NUM_JOBS=${2:-1}
TIME_LIMIT=${3:-2:00:00}

if [[ "$MODEL" != "qwen" && "$MODEL" != "llama" && "$MODEL" != "apertus" ]]; then
    echo "Error: MODEL must be 'qwen' or 'llama' or 'apertus'"
    exit 1
fi

if [[ "$MODEL" == "qwen" ]]; then
    MODEL_PATH="Qwen/Qwen3-32B"
    PARSER_ARGS="--reasoning-parser qwen3 --tool-call-parser qwen25"
    SUBPROCESS="python3 -m sglang.launch_server --model-path ${MODEL_PATH} --host localhost --max-prefill-tokens 32768 --context-length 32768 --port 8080 --tp-size 4 ${PARSER_ARGS}"
    ENV_NAME="/capstor/store/cscs/swissai/a09/xyao/llm_service/sgl.toml"
    SERVER_TYPE="sgl"	
fi
if [[ "$MODEL" == "llama" ]]; then
    MODEL_PATH="meta-llama/Llama-3.3-70B-Instruct"
    PARSER_ARGS=""
    SUBPROCESS="python3 -m sglang.launch_server --model-path ${MODEL_PATH} --host localhost --max-prefill-tokens 32768 --context-length 32768 --port 8080 --tp-size 4 ${PARSER_ARGS}"
    ENV_NAME="/capstor/store/cscs/swissai/a09/xyao/llm_service/sgl.toml"
    SERVER_TYPE="sgl"
fi
if [[ "$MODEL" == "apertus" ]]; then
    MODEL_NAME="swissai/apertus3-70b-15T-sft"
    MODEL_PATH="/capstor/store/cscs/swissai/infra01/swiss-alignment/checkpoints/Apertus3-70B_iter_858000-tulu3-sft/checkpoint-13446"
    PARSER_ARGS=""
    SUBPROCESS="sp serve ${MODEL_PATH} --served-model-name ${MODEL_NAME} --max-prefill-tokens 8192 --context-length 8192 --tp-size 4 --host 0.0.0.0 --port 8080"
    ENV_NAME="/capstor/store/cscs/swissai/a09/xyao/llm_service/sp-dev.toml"
    SERVER_TYPE="sp"
fi

BOOTSTRAP_ADDR=$(curl -s 148.187.108.172:8092/v1/dnt/bootstraps | python3 -c "import sys, json; data = json.load(sys.stdin); print(data['bootstraps'][0] if data.get('bootstraps') else '')")


echo "Submitting $NUM_JOBS $MODEL job(s) with time limit: $TIME_LIMIT"

for ((i=1; i<=NUM_JOBS; i++)); do
    ID=$((1000 + RANDOM % 9000))
    
    cat > temp_${SERVER_TYPE}_${ID}.slurm << EOF
#!/bin/bash
#SBATCH --job-name=${SERVER_TYPE}-${MODEL}-${ID}
#SBATCH --container-writable
#SBATCH --environment=${ENV_NAME}
#SBATCH --time=${TIME_LIMIT}
#SBATCH --ntasks-per-node=1
#SBATCH --dependency=singleton
#SBATCH --account=a-infra01
#SBATCH --output=${SERVER_TYPE}-${MODEL}-%j.out
#SBATCH --error=${SERVER_TYPE}-${MODEL}-%j.err

export NCCL_SOCKET_IFNAME=lo
export GLOO_SOCKET_IFNAME=lo
export PROMETHEUS_MULTIPROC_DIR=/ocfbin/scratch
export SP_NCCL_SO_PATH=/usr/lib/x86_64-linux-gnu/
export NO_PROXY=0.0.0.0,127.0.0.1

/ocfbin/ocf-v2 start --bootstrap.addr "${BOOTSTRAP_ADDR}" --subprocess "${SUBPROCESS}" --service.name llm --service.port 8080
EOF
    
    JOBID=$(sbatch temp_${SERVER_TYPE}_${ID}.slurm | awk '{print $4}')
    rm temp_${SERVER_TYPE}_${ID}.slurm
    
    echo "Job $JOBID submitted"
    echo "Monitor logs: tail -f $(pwd)/${SERVER_TYPE}-${MODEL}-${JOBID}.out"
    echo "Monitor errors: tail -f $(pwd)/${SERVER_TYPE}-${MODEL}-${JOBID}.err"
    echo ""
done

echo "Check status: squeue -u \$USER | grep sgl-"
echo "Cancel all: scancel -u \$USER -n sgl-"
