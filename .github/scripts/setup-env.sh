#!/usr/bin/env bash

set -euo pipefail

# Prepare conda
CONDA_PATH=$(which conda)
eval "$(${CONDA_PATH} shell.bash hook)"
conda config --set channel_priority strict

# Setup the OS_TYPE environment variable that should be used for conditions involving the OS below.
case $(uname) in
  Linux)
    OS_TYPE=linux
    ;;
  Darwin)
    OS_TYPE=macos
    ;;
  *)
    echo "Unknown OS type:" $(uname)
    exit 1
    ;;
esac

echo '::group::Uninstall system JPEG libraries on macOS'
# The x86 macOS runners, e.g. the GitHub Actions native "macos-12" runner, has some JPEG libraries installed by default
# that interfere with our build. We uninstall them here and use the one from conda below.
if [[ "${OS_TYPE}" == "macos" && $(uname -m) == x86_64 ]]; then
  JPEG_LIBS=$(brew list | grep jpeg)
  echo $JPEG_LIBS
  for lib in $JPEG_LIBS; do
    brew uninstall --ignore-dependencies --force $lib || true
  done
fi
echo '::endgroup::'

echo '::group::Set PyTorch conda channel and wheel index'
# TODO: Can we maybe have this as environment variable in the job template? For example, `IS_RELEASE`.
if [[ (${GITHUB_EVENT_NAME} = 'pull_request' && (${GITHUB_BASE_REF} = 'release'*)) || (${GITHUB_REF} = 'refs/heads/release'*) ]]; then
  CHANNEL_ID=test
else
  CHANNEL_ID=nightly
fi
PYTORCH_CONDA_CHANNEL=pytorch-"${CHANNEL_ID}"
echo "PYTORCH_CONDA_CHANNEL=${PYTORCH_CONDA_CHANNEL}"

case $GPU_ARCH_TYPE in
  cpu)
    GPU_ARCH_ID="cpu"
    ;;
  cuda)
    VERSION_WITHOUT_DOT=$(echo "${GPU_ARCH_VERSION}" | sed 's/\.//')
    GPU_ARCH_ID="cu${VERSION_WITHOUT_DOT}"
    ;;
  *)
    echo "Unknown GPU_ARCH_TYPE=${GPU_ARCH_TYPE}"
    exit 1
    ;;
esac
PYTORCH_WHEEL_INDEX="https://download.pytorch.org/whl/${CHANNEL_ID}/${GPU_ARCH_ID}"
echo "PYTORCH_WHEEL_INDEX=${PYTORCH_WHEEL_INDEX}"
echo '::endgroup::'

echo '::group::Create build environment'
# See https://github.com/pytorch/vision/issues/7296 for ffmpeg
conda create \
  --name ci \
  --quiet --yes \
  python="${PYTHON_VERSION}" pip \
  ninja libpng jpeg \
  'ffmpeg<4.3' \
  -c "${PYTORCH_CONDA_CHANNEL}" \
  -c defaults
conda activate ci
pip install --progress-bar=off --upgrade setuptools

# See https://github.com/pytorch/vision/issues/6790
if [[ "${PYTHON_VERSION}" != "3.11" ]]; then
  pip install --progress-bar=off av!=10.0.0
fi

echo '::endgroup::'

echo '::group::Install PyTorch'
pip install --progress-bar=off --pre torch --index-url="${PYTORCH_WHEEL_INDEX}"

if [[ $GPU_ARCH_TYPE == 'cuda' ]]; then
  python3 -c "import torch; exit(not torch.cuda.is_available())"
fi
echo '::endgroup::'

echo '::group::Install TorchVision'
python setup.py develop
echo '::endgroup::'

echo '::group::Collect PyTorch environment information'
python -m torch.utils.collect_env
echo '::endgroup::'
