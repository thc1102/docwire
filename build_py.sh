#!/usr/bin/env bash
set -euo pipefail

# 构建 DocWire Python wheel 包 (使用 uv 工具)
# 前提：已通过 build.sh 完成 C++ 构建，直接复用 vcpkg 中的库

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
DIST_DIR="${ROOT_DIR}/dist"

mkdir -p "${DIST_DIR}"

# 检查并安装 uv
ensure_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    echo "未找到 uv，正在安装..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # 添加 uv 到 PATH
    export PATH="$HOME/.local/bin:$PATH"
    # 验证安装
    if ! command -v uv >/dev/null 2>&1; then
      echo "错误: uv 安装失败" >&2
      exit 1
    fi
    echo "✓ uv 安装成功"
  else
    echo "使用已安装的 uv: $(uv --version)"
  fi
}

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

# 确保 uv 可用
ensure_uv

# Python 版本列表
PYTHON_VERSIONS=("3.8" "3.9" "3.10" "3.11" "3.12")

# 安装所需的 Python 版本
echo "安装 Python 版本..."
for version in "${PYTHON_VERSIONS[@]}"; do
  echo "检查 Python ${version}..."
  # 检查是否已安装：查找版本行且不包含 <download available>
  if uv python list | grep "cpython-${version}" | grep -qv "<download available>"; then
    echo "✓ Python ${version} 已安装"
  else
    echo "安装 Python ${version}..."
    uv python install "${version}"
  fi
done

# 为每个 Python 版本串行构建 wheel
echo "开始构建 wheel 包..."
for version in "${PYTHON_VERSIONS[@]}"; do
  echo ""
  echo "========================================"
  echo "构建 Python ${version} wheel..."
  echo "========================================"
  
  VENV_DIR="${ROOT_DIR}/.venv-${version}"
  
  # 创建临时虚拟环境（包含 pip）
  echo "创建 Python ${version} 虚拟环境..."
  if ! uv venv --seed --python "${version}" "${VENV_DIR}"; then
    echo "⚠ 创建虚拟环境失败，跳过 Python ${version}" >&2
    continue
  fi
  
  # 在虚拟环境中安装构建依赖
  echo "安装构建依赖..."
  if ! uv pip install --python "${VENV_DIR}/bin/python" wheel scikit-build-core pybind11; then
    echo "⚠ 安装构建依赖失败，跳过 Python ${version}" >&2
    rm -rf "${VENV_DIR}"
    continue
  fi
  
  # 使用虚拟环境的 pip 构建 wheel（仅打包 DocWire 库）
  # BUNDLE_ALL_VCPKG=OFF 仅打包 DocWire 核心库，依赖通过 auditwheel 自动检测和修补
  echo "构建 wheel 包（仅打包 DocWire 库）..."
  if "${VENV_DIR}/bin/python" -m pip wheel --no-deps -w "${DIST_DIR}" "${ROOT_DIR}" \
      --config-settings=cmake.define.BUNDLE_ALL_VCPKG=OFF \
      --verbose; then
    echo "✓ Python ${version} wheel 构建成功"
  else
    echo "⚠ Python ${version} wheel 构建失败" >&2
  fi
  
  # 清理临时虚拟环境
  echo "清理虚拟环境..."
  rm -rf "${VENV_DIR}"
done

# 使用 auditwheel 修复 wheel（自动检测和打包依赖）
# 通过设置 LD_LIBRARY_PATH，auditwheel 可以找到 vcpkg 中的依赖库并自动打包
echo ""
echo "========================================"
echo "修复 wheel 包（auditwheel）..."
echo "========================================"

case "$(uname -s)" in
  Linux)
    # 检查并安装 auditwheel
    if ! command -v auditwheel >/dev/null 2>&1; then
      echo "安装 auditwheel..."
      if ! python3 -m pip install --user auditwheel 2>/dev/null; then
        echo "⚠ auditwheel 安装失败，跳过 wheel 修复" >&2
        echo "  可以手动安装: pip install auditwheel" >&2
      fi
    fi
    
    if command -v auditwheel >/dev/null 2>&1; then
      # 设置 LD_LIBRARY_PATH 指向 vcpkg 库目录
      VCPKG_LIB_DIR="${VCPKG_ROOT}/installed/${VCPKG_TARGET_TRIPLET}/lib"
      export LD_LIBRARY_PATH="${VCPKG_LIB_DIR}:${LD_LIBRARY_PATH:-}"
      
      echo "使用 vcpkg 库目录: ${VCPKG_LIB_DIR}"
      
      for whl in "${DIST_DIR}"/*.whl; do
        [[ -f "$whl" ]] || continue
        
        # 跳过已修复的 wheel（带 manylinux 标签）
        if [[ "$(basename "$whl")" == *"manylinux"* ]]; then
          echo "跳过已修复的 wheel: $(basename "$whl")"
          continue
        fi
        
        echo "修复 wheel: $(basename "$whl")"
        
        # 使用 auditwheel repair 自动检测和打包依赖
        if auditwheel repair -w "${DIST_DIR}" "${whl}"; then
          echo "✓ 成功生成 manylinux wheel"
          # 删除原始 wheel
          rm -f "${whl}"
        else
          echo "⚠ auditwheel 修复失败，保留原始 wheel" >&2
        fi
      done
    else
      echo "⚠ 未找到 auditwheel，跳过 wheel 修复"
      echo "  原始 wheel 可在当前系统使用，但跨系统可移植性受限"
    fi
    ;;
    
  Darwin)
    # macOS 使用 delocate
    if command -v delocate-wheel >/dev/null 2>&1; then
      echo "使用 delocate 修复 wheel..."
      for whl in "${DIST_DIR}"/*.whl; do
        [[ -f "$whl" ]] || continue
        echo "修复 wheel: $(basename "$whl")"
        if delocate-wheel -w "${DIST_DIR}" "${whl}"; then
          echo "✓ wheel 修复成功"
          rm -f "${whl}"
        fi
      done
    else
      echo "⚠ 未找到 delocate-wheel，跳过 wheel 修复"
      echo "  可以安装: pip install delocate"
    fi
    ;;
    
  *)
    echo "当前平台不支持自动 wheel 修复"
    ;;
esac

echo ""
echo "========================================"
echo "完成! Wheel 文件位于: ${DIST_DIR}"
echo "========================================"
ls -lh "${DIST_DIR}"/*.whl 2>/dev/null || echo "警告: 没有生成 wheel 文件"
