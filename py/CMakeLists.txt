cmake_minimum_required(VERSION 3.16)
project(docwire_py_bindings LANGUAGES CXX)

# 查找依赖
set(PYBIND11_FINDPYTHON ON)
find_package(pybind11 CONFIG REQUIRED)
find_package(docwire CONFIG REQUIRED)

# 创建 Python 扩展模块
pybind11_add_module(docwire_py MODULE pybind_module.cpp)
target_compile_features(docwire_py PUBLIC cxx_std_20)
target_link_libraries(docwire_py PRIVATE
    docwire_core
    docwire_office_formats
    docwire_mail
    docwire_archives
    docwire_content_type)

# 设置 RPATH：优先从包目录加载动态库
# 扩展模块在 docwire_py/docwire_py.so，动态库在 docwire_py/lib/
if(APPLE)
    set_target_properties(docwire_py PROPERTIES 
        BUILD_RPATH "@loader_path;@loader_path/lib" 
        INSTALL_RPATH "@loader_path;@loader_path/lib")
else()
    set_target_properties(docwire_py PROPERTIES 
        BUILD_RPATH "$ORIGIN;$ORIGIN/lib" 
        INSTALL_RPATH "$ORIGIN;$ORIGIN/lib")
endif()

# 查找并打包 magic.mgc（文件类型检测数据库）
include(GNUInstallDirs)
if(DEFINED VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
    find_file(MAGIC_MGC NAMES magic.mgc
        PATHS "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}"
        PATH_SUFFIXES share/libmagic/misc share/file
        NO_DEFAULT_PATH)
endif()

if(MAGIC_MGC)
    # 开发时：复制到构建目录
    add_custom_command(TARGET docwire_py POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:docwire_py>/share/libmagic/misc"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${MAGIC_MGC}" "$<TARGET_FILE_DIR:docwire_py>/share/libmagic/misc/magic.mgc")
    # 运行时：安装到包目录 docwire_py/share
    install(FILES "${MAGIC_MGC}" DESTINATION docwire_py/${CMAKE_INSTALL_DATADIR}/libmagic/misc)
else()
    message(WARNING "未找到 magic.mgc，wheel 可能需要系统 libmagic 数据库")
endif()

# 安装扩展模块到包目录 docwire_py/
install(TARGETS docwire_py LIBRARY DESTINATION docwire_py)

# 创建 __init__.py 以便导入
install(CODE "
    file(WRITE \"${CMAKE_INSTALL_PREFIX}/docwire_py/__init__.py\" 
\"# DocWire Python 绑定
from .docwire_py import *
__version__ = '0.0.1'
\")
")

# 打包动态库到 wheel
# 选项：BUNDLE_ALL_VCPKG=ON 打包所有 vcpkg 库（自包含但体积大）
#       BUNDLE_ALL_VCPKG=OFF 仅打包实际使用的 DocWire 核心库（体积小，依赖由 auditwheel 自动检测）
option(BUNDLE_ALL_VCPKG "打包所有 vcpkg 动态库以实现完全自包含" ON)

if(DEFINED VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
    set(VCPKG_LIB_DIR "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib")
    
    if(BUNDLE_ALL_VCPKG)
        # 打包所有 .so 文件（包括第三方依赖）
        file(GLOB ALL_SO_FILES "${VCPKG_LIB_DIR}/*.so" "${VCPKG_LIB_DIR}/*.so.*")
        list(LENGTH ALL_SO_FILES SO_COUNT)
        message(STATUS "打包所有 vcpkg 库（${SO_COUNT} 个文件）以实现完全自包含")
        install(FILES ${ALL_SO_FILES} DESTINATION docwire_py/${CMAKE_INSTALL_LIBDIR})
    else()
        # 仅打包 docwire_py.so 直接依赖的 DocWire 库
        # 注意：这些库由 target_link_libraries 决定，必须手动打包到 docwire_py/lib/
        # auditwheel 只负责打包第三方依赖（boost, libxml2 等）到 docwire_py.libs/
        
        # 方案：排除不需要的库（AI、OCR、HTTP 相关）
        file(GLOB ALL_DOCWIRE_LIBS "${VCPKG_LIB_DIR}/libdocwire*.so")
        
        # 排除列表：AI 和其他不需要的功能
        set(EXCLUDE_LIBS
            "libdocwire_ai.so"
            "libdocwire_local_ai.so"
            "libdocwire_openai.so"
            "libdocwire_ocr.so"
            "libdocwire_http.so"
        )
        
        # 过滤掉排除的库
        set(DOCWIRE_SO_FILES)
        foreach(lib_path ${ALL_DOCWIRE_LIBS})
            get_filename_component(lib_name ${lib_path} NAME)
            list(FIND EXCLUDE_LIBS ${lib_name} is_excluded)
            if(is_excluded EQUAL -1)
                list(APPEND DOCWIRE_SO_FILES ${lib_path})
            endif()
        endforeach()
        
        list(LENGTH DOCWIRE_SO_FILES SO_COUNT)
        message(STATUS "打包 DocWire 核心库（${SO_COUNT} 个文件），排除 AI/OCR/HTTP 功能")
        message(STATUS "第三方依赖由 auditwheel 自动检测并打包到 .libs/ 目录")
        install(FILES ${DOCWIRE_SO_FILES} DESTINATION docwire_py/${CMAKE_INSTALL_LIBDIR})
    endif()
else()
    message(WARNING "VCPKG_INSTALLED_DIR 或 VCPKG_TARGET_TRIPLET 未定义，跳过动态库打包")
endif()
