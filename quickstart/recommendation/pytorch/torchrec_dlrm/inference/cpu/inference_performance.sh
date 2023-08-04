# Copyright (c) 2023 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

MODEL_DIR=${MODEL_DIR-$PWD}
if [ ! -e "${MODEL_DIR}/models/recommendation/pytorch/torchrec_dlrm/dlrm_main.py"  ]; then
    echo "Could not find the script of dlrm_s_pytorch.py. Please set environment variable '\${MODEL_DIR}'."
    echo "From which the dlrm_s_pytorch.py exist at the: \${MODEL_DIR}/models/recommendation/pytorch/torchrec_dlrm/dlrm_main.py"
    exit 1
fi
MODEL_SCRIPT=${MODEL_DIR}/models/recommendation/pytorch/torchrec_dlrm/dlrm_main.py
INT8_CONFIG=${MODEL_DIR}/models/recommendation/pytorch/torchrec_dlrm/int8_configure.json

echo "PRECISION: ${PRECISION}"
echo "OUTPUT_DIR: ${OUTPUT_DIR}"

if [ -z "${OUTPUT_DIR}" ]; then
  echo "The required environment variable OUTPUT_DIR has not been set"
  exit 1
fi

# Create the output directory in case it doesn't already exist
mkdir -p ${OUTPUT_DIR}
LOG=${OUTPUT_DIR}/dlrm_inference_performance_log/${PRECISION}
rm -rf ${LOG}
mkdir -p ${LOG}

ARGS=""
if [[ $PRECISION == "bf16" ]]; then
    ARGS="$ARGS --dtype bf16"
    echo "running bf16 path"
elif [[ $PRECISION == "fp32" ]]; then
    echo "running fp32 path"
    ARGS="$ARGS --dtype fp32"
elif [[ $PRECISION == "bf32" ]]; then
    echo "running bf32 path"
    ARGS="$ARGS --dtype bf32"
elif [[ $PRECISION == "fp16" ]]; then
    echo "running fp16 path"
    ARGS="$ARGS --dtype fp16"
elif [[ $PRECISION == "int8" ]]; then
    echo "running int8 path"
    ARGS="$ARGS --dtype int8 --int8-configure-dir ${INT8_CONFIG}"
else
    echo "The specified PRECISION '${PRECISION}' is unsupported."
    echo "Supported PRECISIONs are: fp32, fp16, bf16, bf32, int8"
    exit 1
fi

if [ -z "${DATASET_DIR}" ]; then
  echo "DATASET_DIR are not set, will use dummy generated dataset"
  ARGS="$ARGS --multi_hot_distribution_type uniform "
  ARGS="$ARGS --multi_hot_sizes 3,2,1,2,6,1,1,1,1,7,3,8,1,6,9,5,1,1,1,12,100,27,10,3,1,1 "
else
  ARGS="$ARGS --synthetic_multi_hot_criteo_path $DATASET_DIR "
fi

LOG_0="${LOG}/throughput.log"
export BATCH_SIZE=32768
python -m intel_extension_for_pytorch.cpu.launch --throughput_mode --enable_jemalloc $MODEL_SCRIPT \
    --embedding_dim 128 \
    --dense_arch_layer_sizes 512,256,128 \
    --over_arch_layer_sizes 1024,1024,512,256,1 \
    --num_embeddings_per_feature 40000000,39060,17295,7424,20265,3,7122,1543,63,40000000,3067956,405282,10,2209,11938,155,4,976,14,40000000,40000000,40000000,590152,12973,108,36 \
    --epochs 1 \
    --pin_memory \
    --mmap_mode \
    --batch_size $BATCH_SIZE \
    --interaction_type=dcn \
    --dcn_num_layers=3 \
    --dcn_low_rank_dim=512 \
    --limit_val_batches 100 \
    --ipex-optimize \
    --log-freq 10 \
    --jit \
    --inference-only \
    $ARGS 2>&1 | tee $LOG_0
wait

throughput=$(grep 'Throughput:' ${LOG}/throughput.log |sed -e 's/.*Throughput//;s/[^0-9.]//g' |awk '
BEGIN {
        sum = 0;
        i = 0;
      }
      {
        sum = sum + $1;
        i++;
      }
END   {
sum = sum / i;
        printf("%.3f", sum);
}')
echo ""dlrm-v2";"throughput";${PRECISION};${BATCH_SIZE};${throughput}" | tee -a ${OUTPUT_DIR}/summary.log