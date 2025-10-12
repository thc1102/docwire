/*********************************************************************************************************************************************/
/*  DocWire SDK: 非 AI 功能的 pybind11 绑定                                                                                                  */
/*                                                                                                                                           */
/*  本模块提供 DocWire 核心流水线的最小化、无 AI 接口：                                                                                        */
/*  - 检测内容类型                                                                                                                           */
/*  - 解析档案、Office 格式、邮件以及可选的 OCR                                                                                                */
/*  - 导出为纯文本、HTML、CSV 或元数据                                                                                                        */
/*                                                                                                                                           */
/*  注意：有意避免包含任何 AI 相关头文件（OpenAI、本地 AI、嵌入等）                                                                              */
/*********************************************************************************************************************************************/

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include <filesystem>
#include <optional>
#include <sstream>
#include <string>
#include <vector>
#include <cstring>

// DocWire 头文件 - 仅核心和非 AI 功能（已安装的 include 布局）
#include <docwire/archives_parser.h>
#include <docwire/content_type.h>
#include <docwire/csv_exporter.h>
#include <docwire/data_source.h>
#include <docwire/html_exporter.h>
#include <docwire/input.h>
#include <docwire/log.h>
#include <docwire/mail_parser.h>
#include <docwire/meta_data_exporter.h>
#include <docwire/office_formats_parser.h>
#include <docwire/output.h>
#include <docwire/parsing_chain.h>
#include <docwire/plain_text_exporter.h>
#include <docwire/standard_filter.h>

namespace py = pybind11;

namespace
{
enum class OutputType { plain_text, html, csv, metadata };

// 辅助函数
static std::vector<std::byte> to_bytes(const std::string& s)
{
    std::vector<std::byte> out(s.size());
    std::memcpy(out.data(), s.data(), s.size());
    return out;
}

template <typename ChainLike>
static void append_filters(ChainLike& chain,
                           const std::optional<unsigned int>& max_nodes_number,
                           const std::optional<unsigned int>& min_creation_time,
                           const std::optional<unsigned int>& max_creation_time,
                           const std::optional<std::string>& folder_name,
                           const std::optional<std::string>& attachment_extension)
{
    using namespace docwire;
    if (max_nodes_number) {
        chain |= StandardFilter::filterByMaxNodeNumber(*max_nodes_number);
    }
    if (min_creation_time) {
        chain |= StandardFilter::filterByMailMinCreationTime(*min_creation_time);
    }
    if (max_creation_time) {
        chain |= StandardFilter::filterByMailMaxCreationTime(*max_creation_time);
    }
    if (folder_name && !folder_name->empty()) {
        chain |= StandardFilter::filterByFolderName({*folder_name});
    }
    if (attachment_extension && !attachment_extension->empty()) {
        chain |= StandardFilter::filterByAttachmentType({docwire::file_extension{*attachment_extension}});
    }
}

template <typename ChainLike>
static void append_exporter(ChainLike& chain, OutputType t)
{
    using namespace docwire;
    switch (t)
    {
        case OutputType::plain_text:
            chain |= PlainTextExporter();
            break;
        case OutputType::html:
            chain |= HtmlExporter();
            break;
        case OutputType::csv:
            chain |= CsvExporter();
            break;
        case OutputType::metadata:
            chain |= MetaDataExporter();
            break;
    }
}
} // 匿名命名空间

static std::string process_path(
    const std::string& path,
    OutputType output,
    std::optional<unsigned int> max_nodes_number,
    std::optional<unsigned int> min_creation_time,
    std::optional<unsigned int> max_creation_time,
    std::optional<std::string> folder_name,
    std::optional<std::string> attachment_extension,
    bool verbose)
{
    using namespace docwire;

    if (verbose) set_log_verbosity(debug);

    auto chain = std::filesystem::path{path} | content_type::detector{};

    chain |= archives_parser{} | office_formats_parser{} | mail_parser{};

    append_filters(chain, max_nodes_number, min_creation_time, max_creation_time, folder_name, attachment_extension);
    append_exporter(chain, output);

    std::ostringstream oss;
    chain |= oss;
    return oss.str();
}

static std::string process_bytes(
    py::bytes data,
    OutputType output,
    std::optional<std::string> file_ext,
    std::optional<unsigned int> max_nodes_number,
    std::optional<unsigned int> min_creation_time,
    std::optional<unsigned int> max_creation_time,
    std::optional<std::string> folder_name,
    std::optional<std::string> attachment_extension,
    bool verbose)
{
    using namespace docwire;

    if (verbose) set_log_verbosity(debug);

    std::string s = data; // copies from Python bytes
    auto buffer = to_bytes(s);

    ParsingChain chain = file_ext && !file_ext->empty()
        ? (data_source{buffer, file_extension{*file_ext}} | content_type::detector{})
        : (data_source{buffer} | content_type::detector{});

    chain |= archives_parser{} | office_formats_parser{} | mail_parser{};

    append_filters(chain, max_nodes_number, min_creation_time, max_creation_time, folder_name, attachment_extension);
    append_exporter(chain, output);

    std::ostringstream oss;
    chain |= oss;
    return oss.str();
}

PYBIND11_MODULE(docwire_py, m)
{
    m.doc() = "DocWire Python 绑定（非 AI）";

    py::enum_<OutputType>(m, "OutputType")
        .value("plain_text", OutputType::plain_text)
        .value("html", OutputType::html)
        .value("csv", OutputType::csv)
        .value("metadata", OutputType::metadata)
        .export_values();

    m.def(
        "process_path",
        &process_path,
        py::arg("path"),
        py::arg("output") = OutputType::plain_text,
        py::arg("max_nodes_number") = std::optional<unsigned int>{},
        py::arg("min_creation_time") = std::optional<unsigned int>{},
        py::arg("max_creation_time") = std::optional<unsigned int>{},
        py::arg("folder_name") = std::optional<std::string>{},
        py::arg("attachment_extension") = std::optional<std::string>{},
        py::arg("verbose") = false,
        R"doc(
使用 DocWire 的非 AI 流水线处理文件路径（无 OCR）。

参数：
  path: 输入文件路径。
  output: 输出类型：plain_text|html|csv|metadata。
  max_nodes_number, min_creation_time, max_creation_time, folder_name, attachment_extension: 可选过滤器。
  verbose: 启用详细日志输出到 stderr。

返回：
  指定格式的字符串内容。
)doc");

    m.def(
        "process_bytes",
        &process_bytes,
        py::arg("data"),
        py::arg("output") = OutputType::plain_text,
        py::arg("file_ext") = std::optional<std::string>{},
        py::arg("max_nodes_number") = std::optional<unsigned int>{},
        py::arg("min_creation_time") = std::optional<unsigned int>{},
        py::arg("max_creation_time") = std::optional<unsigned int>{},
        py::arg("folder_name") = std::optional<std::string>{},
        py::arg("attachment_extension") = std::optional<std::string>{},
        py::arg("verbose") = false,
        R"doc(
使用 DocWire 的非 AI 流水线处理二进制数据（无 OCR）。

参数：
  data: Python bytes 输入数据。
  output: 输出类型：plain_text|html|csv|metadata。
  file_ext: 可选的文件扩展名提示（例如 "pdf"）。
  max_nodes_number, min_creation_time, max_creation_time, folder_name, attachment_extension: 可选过滤器。
  verbose: 启用详细日志输出到 stderr。

返回：
  指定格式的字符串内容。
)doc");
}
