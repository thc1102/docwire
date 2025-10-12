#!/usr/bin/env bash
set -euo pipefail

# 构建 DocWire Python wheel 包
# 前提：已通过 build.sh 完成 C++ 构建，直接复用 vcpkg 中的库

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
DIST_DIR="${ROOT_DIR}/dist"

mkdir -p "${DIST_DIR}"

# 检测平台对应的 vcpkg triplet
platform_triplet() {
  case "$(uname -s)" in
    Linux) echo "x64-linux-dynamic" ;;
    Darwin)
      [[ $(uname -m) == "arm64" ]] && echo "arm64-osx-dynamic" || echo "x64-osx-dynamic"
      ;;
    *) echo "x64-linux-dynamic" ;;
  esac
}

# 配置 vcpkg 路径
VCPKG_ROOT="${VCPKG_ROOT:-${ROOT_DIR}/vcpkg}"
VCPKG_TARGET_TRIPLET="${VCPKG_TARGET_TRIPLET:-$(platform_triplet)}"

# 验证 vcpkg 中的 docwire 是否已构建
if [[ ! -f "${VCPKG_ROOT}/installed/${VCPKG_TARGET_TRIPLET}/share/docwire/docwire-config.cmake" ]]; then
  echo "错误: 未在 vcpkg 中找到已构建的 docwire" >&2
  echo "请先运行 build.sh 构建 C++ 库" >&2
  exit 1
fi

echo "使用 vcpkg docwire (${VCPKG_TARGET_TRIPLET}): ${VCPKG_ROOT}"
export CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake -DVCPKG_TARGET_TRIPLET=${VCPKG_TARGET_TRIPLET} ${CMAKE_ARGS:-}"

# 查找 Python 解释器
find_python() {
  for cmd in python3 python; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "$cmd"
      return 0
    fi
  done
  return 1
}

PYTHON=$(find_python || true)
if [[ -z "${PYTHON}" ]]; then
  echo "错误: 未找到 Python 解释器，请安装 Python 3.8+" >&2
  exit 2
fi

echo "使用 Python: ${PYTHON} ($(${PYTHON} -c 'import sys;print(sys.version.split()[0])'))"

# 确保 pip 可用
if ! ${PYTHON} -m pip --version >/dev/null 2>&1; then
  echo "错误: pip 不可用，请安装 python3-pip" >&2
  exit 3
fi

# 安装构建依赖（处理 PEP 668 外部管理环境限制）
echo "安装 Python 构建依赖..."
PIP_ARGS="--upgrade pip wheel scikit-build-core pybind11"

# 尝试正常安装，失败则使用 --break-system-packages
if ! ${PYTHON} -m pip install ${PIP_ARGS} 2>/dev/null; then
  echo "检测到外部管理环境，使用 --break-system-packages 标志..."
  ${PYTHON} -m pip install --break-system-packages ${PIP_ARGS}
fi

# 根据平台安装 wheel 修复工具
case "$(uname -s)" in
  Linux)
    ${PYTHON} -m pip install --upgrade auditwheel 2>/dev/null || \
    ${PYTHON} -m pip install --break-system-packages --upgrade auditwheel 2>/dev/null || true
    ;;
  Darwin)
    ${PYTHON} -m pip install --upgrade delocate 2>/dev/null || \
    ${PYTHON} -m pip install --break-system-packages --upgrade delocate 2>/dev/null || true
    ;;
esac

# 构建 wheel
echo "构建 Python wheel..."
echo "提示：首次构建需要 2-5 分钟，正在编译 C++ 扩展..."
${PYTHON} -m pip wheel --no-deps -w "${DIST_DIR}" "${ROOT_DIR}" --verbose

# 修复 wheel（捆绑动态库）
# 注意：由于 DocWire 依赖大量 vcpkg 第三方库，auditwheel 可能失败
# 但 wheel 已设置正确的 RPATH，可以直接使用
case "$(uname -s)" in
  Linux)
    if command -v auditwheel >/dev/null 2>&1 && command -v patchelf >/dev/null 2>&1; then
      echo "尝试使用 auditwheel 修复 wheel..."
      for whl in "${DIST_DIR}"/*.whl; do
        [[ -f "$whl" ]] || continue
        echo "处理: $(basename "$whl")"
        
        # 尝试修复，失败不影响整体结果
        if auditwheel repair -w "${DIST_DIR}" "${whl}" 2>/dev/null; then
          echo "✓ 成功生成 manylinux wheel"
          rm -f "${whl}"
        else
          echo "⚠ auditwheel 修复失败（预期行为）"
          echo "  原因：包含大量 vcpkg 依赖，难以完全捆绑"
          echo "  影响：wheel 在当前系统可用，跨系统可移植性受限"
        fi
      done
    else
      echo "跳过 auditwheel 修复（未安装 patchelf 或 auditwheel）"
    fi
    ;;
  Darwin)
    if command -v delocate-wheel >/dev/null 2>&1; then
      for whl in "${DIST_DIR}"/*.whl; do
        [[ -f "$whl" ]] || continue
        echo "修复 wheel: $(basename "$whl")"
        delocate-wheel -w "${DIST_DIR}" "${whl}" && rm -f "${whl}"
      done
    fi
    ;;
esac

echo "完成! Wheel 文件位于: ${DIST_DIR}"
ls -lh "${DIST_DIR}"/*.whl
