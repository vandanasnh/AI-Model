#!/usr/bin/env bash
#
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

CORES_PER_INSTANCE="socket"

MODEL_DIR=${MODEL_DIR-$PWD}

if [ -z "${OUTPUT_DIR}" ]; then
  echo "The required environment variable OUTPUT_DIR has not been set"
  exit 1
fi

# Create the output directory in case it doesn't already exist
mkdir -p ${OUTPUT_DIR}

if [ -z "${CHECKPOINT_DIR}" ]; then
  echo "The required Checkpoint directory has not been set."
  echo "Please set a directory where the model and data will be downloaded."
  exit 1
fi

if [ ! -d "${CHECKPOINT_DIR}" ]; then
  echo "The CHECKPOINT_DIR '${CHECKPOINT_DIR}' does not exist. The script will download the saved model."
  mkdir -p ${CHECKPOINT_DIR}
fi

if [ -z "${PRECISION}" ]; then
  echo "The required environment variable PRECISION has not been set"
  echo "Please set PRECISION to fp32, bfloat16 or fp16."
  exit 1
elif [ ${PRECISION} != "fp32" ] && [ ${PRECISION} != "bfloat16" ] && [ ${PRECISION} != "fp16" ]; then
  echo "The specified precision '${PRECISION}' is unsupported."
  echo "Supported precisions are: fp32, bfloat16 and fp16"
  exit 1
fi

RAM=$(grep MemTotal /proc/meminfo | sed 's/[^0-9]//g')
RAMG=$((RAM / 1024 / 1024))
NUMNUMA=$(lscpu |grep 'NUMA node(s):' |sed 's/[^0-9]//g')
MEMPERNUMA=$((RAM / 1024 / 1024 / NUMNUMA))

# By default we choose the maximum batch size 
# that the host system memory allows for the LLM. 

if [ -z "${BATCH_SIZE}" ]; then
  if [ "${PRECISION}" == "fp32" ]; then
    if [[ $MEMPERNUMA -lt 249 ]]; then
      BATCH_SIZE="107"
    else
      BATCH_SIZE="214"
    fi
  else
    if [[ $MEMPERNUMA -lt 249 ]]; then
      BATCH_SIZE="214"
    else
      BATCH_SIZE="428"
    fi
  fi
  echo "Running with default batch size of ${BATCH_SIZE}"
fi

if [ -z "${MAX_OUTPUT_TOKENS}" ]; then
  MAX_OUTPUT_TOKENS="32"
  echo "Running with default max output token size of ${MAX_OUTPUT_TOKENS}"
fi

if [ -z "${INPUT_TOKENS}" ]; then
  INPUT_TOKENS="32"
  echo "Running with default input token size of ${INPUT_TOKENS}"
fi

if [ -z "${STEPS}" ]; then
  STEPS="14"
  echo "Running with default benchmarking steps of ${STEPS}"
fi

if [ -z "${WARMUP_STEPS}" ]; then
  WARMUP_STEPS="2"
  echo "Running with default benchmarking warmup steps of ${WARMUP_STEPS}"
fi

if [ -z "${DUMMY_DATA}" ]; then
  DUMMY_DATA="1"
  echo "Running with dummy data"
fi

cores_per_socket=$(lscpu |grep 'Core(s) per socket:' |sed 's/[^0-9]//g')
export OMP_NUM_THREADS=${cores_per_socket}

source "${MODEL_DIR}/quickstart/language_modeling/tensorflow/gpt_j/inference/cpu/apply.sh"
source "${MODEL_DIR}/quickstart/common/utils.sh"

_command python ${MODEL_DIR}/benchmarks/launch_benchmark.py \
  --model-name=gpt_j \
  --precision=${PRECISION} \
  --mode=inference \
  --framework tensorflow \
  --output-dir ${OUTPUT_DIR} \
  --checkpoint=${CHECKPOINT_DIR} \
  --batch-size=${BATCH_SIZE} \
  --numa-cores-per-instance ${CORES_PER_INSTANCE} \
  --benchmark-only \
  --num-intra-threads ${cores_per_socket} \
  --num-inter-threads 1 \
  $@ \
  -- max_output_tokens=${MAX_OUTPUT_TOKENS} \
  input_tokens=${INPUT_TOKENS} \
  steps=${STEPS} \
  warmup_steps=${WARMUP_STEPS} \
  dummy_data=${DUMMY_DATA}

if [[ $? == 0 ]]; then
  cat ${OUTPUT_DIR}/gpt_j_${PRECISION}_inference_bs${BATCH_SIZE}_cores*_all_instances.log | grep -ie "Time spent per iteration" | sed -e "s/.*://;s/ms//"
  echo "Throughput summary:"
  grep "Inference generation throughput (tokens / sec)" ${OUTPUT_DIR}/gpt_j_${PRECISION}_inference_bs${BATCH_SIZE}_cores*_all_instances.log | awk ' {sum+=$(NF);} END{print sum} '
  exit 0
else
  exit 1
fi
