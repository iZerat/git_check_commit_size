#!/bin/bash

# 脚本名称: git_commit_size.sh
# 功能: 查询最近n次提交的实际变更文件体积大小
# 改进版：准确计算每次提交的变更文件大小，优化速度，并正确处理重命名文件

# 设置默认提交次数
DEFAULT_COMMITS=5
PAUSE_AFTER_COMPLETE=true  # 完成后是否暂停

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 显示帮助信息
show_help() {
    echo -e "${CYAN}使用方法:${NC}"
    echo -e "  $0 [n]"
    echo -e "  $0 -h 或 --help 显示帮助信息"
    echo ""
    echo -e "${CYAN}参数说明:${NC}"
    echo -e "  n: 要查询的最近提交次数，默认为 ${GREEN}${DEFAULT_COMMITS}${NC}"
    echo ""
    echo -e "${CYAN}示例:${NC}"
    echo -e "  $0          # 查询最近5次提交"
    echo -e "  $0 10       # 查询最近10次提交"
    echo -e "  $0 1        # 查询最近1次提交"
    echo -e "  $0 -h       # 显示帮助信息"
    echo ""
}

# 检查是否支持bc命令，如果不支持则使用awk
check_bc() {
    if command -v bc >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 将字节转换为方便阅读的格式
format_size() {
    local bytes=$1
    
    if check_bc; then
        # 使用bc进行精确计算
        if [ $bytes -ge $((1024*1024*1024)) ]; then
            echo "$(echo "scale=2; $bytes/(1024*1024*1024)" | bc) GB"
        elif [ $bytes -ge $((1024*1024)) ]; then
            echo "$(echo "scale=2; $bytes/(1024*1024)" | bc) MB"
        elif [ $bytes -ge 1024 ]; then
            echo "$(echo "scale=2; $bytes/1024" | bc) KB"
        else
            echo "$bytes B"
        fi
    else
        # 使用awk进行近似计算
        if [ $bytes -ge $((1024*1024*1024)) ]; then
            echo "$(awk "BEGIN {printf \"%.2f GB\", $bytes/(1024*1024*1024)}")"
        elif [ $bytes -ge $((1024*1024)) ]; then
            echo "$(awk "BEGIN {printf \"%.2f MB\", $bytes/(1024*1024)}")"
        elif [ $bytes -ge 1024 ]; then
            echo "$(awk "BEGIN {printf \"%.2f KB\", $bytes/1024}")"
        else
            echo "$bytes B"
        fi
    fi
}

# 安全的算术运算函数
safe_add() {
    local a=$1
    local b=$2
    # 确保两个参数都是数字，如果，如果不是则设为0
    [[ $a =~ ^[0-9]+$ ]] || a=0
    [[ $b =~ ^[0-9]+$ ]] || b=0
    echo $((a + b))
}

# 解析git show --stat输出，获取文件数量和插入行数
parse_git_show_stat() {
    local commit_hash=$1
    local stat_output
    
    # 使用git show --stat获取统计信息，取最后一行
    stat_output=$(git show --stat "$commit_hash" 2>/dev/null | tail -5 | grep -E "(files? changed|insertions|deletions)" | tail -1)
    
    local files_changed=0
    local insertions=0
    
    if [ -n "$stat_output" ]; then
        # 提取文件数量，例如: "3 files changed, 150 insertions(+), 20 deletions(-)"
        # 或者: "1 file changed, 5 insertions(+)"
        files_changed=$(echo "$stat_output" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo "0")
        
        # 如果没有匹配到"files changed"，尝试其他格式
        if [ "$files_changed" = "0" ]; then
            files_changed=$(echo "$stat_output" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
        fi
        
        # 提取插入行数
        insertions=$(echo "$stat_output" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        
        # 如果没有找到插入行数，尝试其他格式
        if [ "$insertions" = "0" ]; then
            insertions=$(echo "$stat_output" | grep -oE '[0-9]+ insertions' | grep -oE '[0-9]+' || echo "0")
        fi
    fi
    
    echo "$files_changed|$insertions"
}

# 检查提交是否为初次提交
is_initial_commit() {
    local commit_hash=$1
    
    # 尝试获取父提交
    if git rev-parse "${commit_hash}^" > /dev/null 2>&1; then
        echo "false"
    else
        echo "true"
    fi
}

# 获取重命名文件列表和详细信息
get_renamed_files() {
    local parent_commit=$1
    local commit_hash=$2
    
    # 使用git diff --name-status --diff-filter=R 获取重命名文件列表
    local renamed_files_info
    renamed_files_info=$(git diff --name-status --diff-filter=R "$parent_commit" "$commit_hash" 2>/dev/null)
    
    if [ -z "$renamed_files_info" ]; then
        echo ""  # 没有重命名文件
        return
    fi
    
    # 格式: R<tab>旧文件名<tab>新文件名
    # 创建一个关联数组来存储重命名信息（在bash中，使用declare -A）
    local rename_map=""
    
    while IFS=$'\t' read -r status old_file new_file; do
        if [ -n "$old_file" ] && [ -n "$new_file" ]; then
            # 添加到映射字符串中，格式为 "old_file:new_file|old_file2:new_file2|..."
            if [ -z "$rename_map" ]; then
                rename_map="${old_file}:${new_file}"
            else
                rename_map="${rename_map}|${old_file}:${new_file}"
            fi
        fi
    done <<< "$renamed_files_info"
    
    echo "$rename_map"
}

# 检查文件是否在重命名映射中
is_file_renamed() {
    local file_path=$1
    local rename_map=$2
    
    if [ -z "$rename_map" ]; then
        echo "false"
        return
    fi
    
    # 检查文件是否作为新文件名存在于重命名映射中
    IFS='|' read -ra rename_entries <<< "$rename_map"
    for entry in "${rename_entries[@]}"; do
        if [ -n "$entry" ]; then
            IFS=':' read -r old_file new_file <<< "$entry"
            if [ "$new_file" = "$file_path" ]; then
                echo "true"
                return
            fi
        fi
    done
    
    echo "false"
}

# 获取重命名文件的旧文件名
get_old_filename_for_renamed() {
    local new_file_path=$1
    local rename_map=$2
    
    if [ -z "$rename_map" ]; then
        echo ""
        return
    fi
    
    IFS='|' read -ra rename_entries <<< "$rename_map"
    for entry in "${rename_entries[@]}"; do
        if [ -n "$entry" ]; then
            IFS=':' read -r old_file new_file <<< "$entry"
            if [ "$new_file" = "$new_file_path" ]; then
                echo "$old_file"
                return
            fi
        fi
    done
    
    echo ""
}

# 获取单个提交的变更文件大小（精确方法，计算实际变更字节数）
get_commit_changed_size_accurate() {
    local commit_hash=$1
    local size_bytes=0
    
    # 检查是否为初次提交
    local is_initial
    is_initial=$(is_initial_commit "$commit_hash")
    
    if [ "$is_initial" = "false" ]; then
        # 有父提交：使用git diff计算实际变更字节数
        local parent_commit
        parent_commit=$(git rev-parse "${commit_hash}^" 2>/dev/null)
        
        # 获取重命名文件映射
        local rename_map
        rename_map=$(get_renamed_files "$parent_commit" "$commit_hash")
        
        # 获取所有变更文件列表
        local changed_files
        changed_files=$(git diff --name-only "$parent_commit" "$commit_hash" 2>/dev/null)
        
        # 统计重命名文件数量
        local renamed_count=0
        if [ -n "$rename_map" ]; then
            renamed_count=$(echo "$rename_map" | grep -o "|" | wc -l)
            renamed_count=$((renamed_count + 1))  # 加1是因为最后没有管道符
            # echo -e "  ${BLUE}检测到 ${renamed_count} 个重命名文件${NC}" >&2
        fi
        
        if [ -n "$changed_files" ]; then
            # 遍历每个变更文件，计算实际变更字节数
            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    # 检查是否为重命名文件
                    local is_renamed
                    is_renamed=$(is_file_renamed "$file" "$rename_map")
                    
                    if [ "$is_renamed" = "true" ]; then
                        # 重命名文件：只计算文件路径变化的开销，而不是整个文件内容
                        # 假设文件路径变化平均开销为100字节（路径长度变化）
                        local old_filename
                        old_filename=$(get_old_filename_for_renamed "$file" "$rename_map")
                        
                        # 计算旧文件名和新文件名的长度差异（字节数）
                        local old_len=${#old_filename}
                        local new_len=${#file}
                        local path_diff=$((new_len - old_len))
                        if [ $path_diff -lt 0 ]; then
                            path_diff=$((-path_diff))
                        fi
                        
                        # 重命名操作的开销：路径差异 + 固定开销（元数据变更）
                        local rename_cost=$((path_diff + 100))
                        size_bytes=$(safe_add "$size_bytes" "$rename_cost")
                        
                        # 显示重命名信息
                        # echo -e "    ${CYAN}重命名: ${old_filename} -> ${file} (开销: $rename_cost 字节)${NC}" >&2
                    else
                        # 非重命名文件：使用git diff获取文件的实际变更内容并计算字节数
                        # --diff-filter=ACMT 只考虑添加、复制、修改、类型变更的文件（排除重命名）
                        local diff_output
                        diff_output=$(git diff --diff-filter=ACMT --binary "$parent_commit" "$commit_hash" -- "$file" 2>/dev/null)
                        
                        # 计算差异内容的字节数（排除diff头部信息）
                        # 对于二进制文件，git diff会显示"Binary files ... differ"，我们需要获取实际文件大小差异
                        if echo "$diff_output" | grep -q "Binary files"; then
                            # 二进制文件：计算两个版本的大小差异
                            local parent_size=0
                            local current_size=0
                            local diff_size=0
                            
                            # 获取父提交中的文件大小
                            if git show "$parent_commit:$file" >/dev/null 2>&1; then
                                parent_size=$(git show "$parent_commit:$file" 2>/dev/null | wc -c | tr -d ' ')
                            fi
                            
                            # 获取当前提交中的文件大小
                            if git show "$commit_hash:$file" >/dev/null 2>&1; then
                                current_size=$(git show "$commit_hash:$file" 2>/dev/null | wc -c | tr -d ' ')
                            fi
                            
                            # 计算大小差异（绝对值）
                            diff_size=$((current_size - parent_size))
                            if [ $diff_size -lt 0 ]; then
                                diff_size=$((-diff_size))
                            fi
                            
                            # 如果没有变化，但git diff报告为二进制文件不同，则可能是权限变化等
                            if [ $diff_size -eq 0 ]; then
                                diff_size=100  # 元数据变化的最小开销
                            fi
                            
                            size_bytes=$(safe_add "$size_bytes" "$diff_size")
                        elif [ -n "$diff_output" ]; then
                            # 文本文件：计算差异内容的实际字节数（排除diff元数据）
                            # 过滤掉diff头部行（以---、+++、@@开头的行）
                            local content_bytes
                            content_bytes=$(echo "$diff_output" | grep -v '^---\|^+++\|^@@' | wc -c | tr -d ' ')
                            size_bytes=$(safe_add "$size_bytes" "$content_bytes")
                        else
                            # 没有差异输出，可能是元数据变更（如权限、模式变更）
                            # 给予最小的开销估算
                            size_bytes=$(safe_add "$size_bytes" "100")
                        fi
                    fi
                fi
            done <<< "$changed_files"
        fi
        
        # 如果没有计算到任何变更，可能是因为所有变更都是重命名或元数据变更
        if [ $size_bytes -eq 0 ] && [ -n "$changed_files" ]; then
            # 最小开销：每个文件100字节（元数据变更）
            local file_count
            file_count=$(echo "$changed_files" | wc -l | tr -d ' ')
            size_bytes=$((file_count * 100))
        fi
    else
        # 初次提交：使用git ls-tree获取所有文件并计算实际大小
        local total_size=0
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                # git ls-tree -r -l的输出格式: mode type hash size path
                local file_size
                file_size=$(echo "$line" | awk '{print $4}')
                if [[ $file_size =~ ^[0-9]+$ ]] && [ "$file_size" -gt 0 ]; then
                    total_size=$((total_size + file_size))
                fi
            fi
        done < <(git ls-tree -r -l "$commit_hash" 2>/dev/null)
        
        size_bytes=$total_size
        
        # 如果通过git ls-tree获取到了实际大小，则使用它
        if [ "$size_bytes" -gt 0 ]; then
            >&2
        else
            # 如果git ls-tree失败，则使用git show --stat估算
            >&2
            
            # 解析git show --stat输出
            local stat_info
            stat_info=$(parse_git_show_stat "$commit_hash")
            IFS='|' read -r files_changed insertions <<< "$stat_info"
            
            # 确保files_changed和insertions是数字
            [[ $files_changed =~ ^[0-9]+$ ]] || files_changed=0
            [[ $insertions =~ ^[0-9]+$ ]] || insertions=0
            
            # 如果有插入行数，使用估算方法
            if [ "$insertions" -gt 0 ]; then
                # 假设平均每行100字节
                size_bytes=$((insertions * 100))
                echo -e "  ${BLUE}使用插入行数估算: $insertions 行 * 100字节/行 = $size_bytes 字节${NC}" >&2
            else
                # 如果无法获取插入行数，使用文件数量估算
                if [ "$files_changed" -gt 0 ]; then
                    # 每个文件平均5KB
                    size_bytes=$((files_changed * 5120))
                    echo -e "  ${BLUE}使用文件数量估算: $files_changed 个文件 * 5120字节/文件 = $size_bytes 字节${NC}" >&2
                else
                    # 默认估算为10KB
                    size_bytes=10240
                    echo -e "  ${BLUE}使用默认估算: 10240 字节${NC}" >&2
                fi
            fi
        fi
    fi
    
    # 确保返回的是数字
    [[ $size_bytes =~ ^[0-9]+$ ]] || size_bytes=0
    echo "$size_bytes"
}

# 获取单个提交的变更文件大小（快速方法）
get_commit_changed_size_fast() {
    local commit_hash=$1
    local size_bytes=0
    
    # 检查是否为初次提交
    local is_initial
    is_initial=$(is_initial_commit "$commit_hash")
    
    if [ "$is_initial" = "false" ]; then
        # 有父提交：使用git diff --stat估算
        local stat_output
        stat_output=$(git diff --shortstat "${commit_hash}^" "$commit_hash" 2>/dev/null)
        
        if [ -n "$stat_output" ]; then
            # 解析例如: 3 files changed, 150 insertions(+), 20 deletions(-)
            local files_changed
            local insertions
            files_changed=$(echo "$stat_output" | grep -oE '[0-9]+ files?' | grep -oE '[0-9]+' || echo "0")
            insertions=$(echo "$stat_output" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
            
            # 确保是数字
            [[ $files_changed =~ ^[0-9]+$ ]] || files_changed=0
            [[ $insertions =~ ^[0-9]+$ ]] || insertions=0
            
            # 简单估算：假设平均每行100字节，每个文件增加50行
            if [ "$files_changed" -gt 0 ]; then
                # 基于文件数量和插入行数估算
                size_bytes=$((files_changed * 5120 + insertions * 100))  # 每个文件5KB + 每行100字节
            fi
            
            # 尝试检测重命名文件并调整估算
            local renamed_files_info
            renamed_files_info=$(git diff --name-status --diff-filter=R "${commit_hash}^" "$commit_hash" 2>/dev/null | wc -l)
            if [ "$renamed_files_info" -gt 0 ]; then
                # 有重命名文件：从估算中减去重命名文件的大小（假设每个重命名文件平均50KB）
                # 然后加上重命名操作的开销（假设每个100字节）
                local renamed_adjustment=$((renamed_files_info * 50000 - renamed_files_info * 100))
                size_bytes=$((size_bytes - renamed_adjustment))
                if [ $size_bytes -lt 0 ]; then
                    size_bytes=0
                fi
                echo -e "  ${CYAN}快速估算中检测到 ${renamed_files_info} 个重命名文件，已调整估算值${NC}" >&2
            fi
        fi
    else
        # 初次提交：使用git show --stat获取更准确的信息
        echo -e "  ${CYAN}检测到初次提交，使用git show --stat分析...${NC}" >&2
        
        # 解析git show --stat输出
        local stat_info
        stat_info=$(parse_git_show_stat "$commit_hash")
        IFS='|' read -r files_changed insertions <<< "$stat_info"
        
        # 确保是数字
        [[ $files_changed =~ ^[0-9]+$ ]] || files_changed=0
        [[ $insertions =~ ^[0-9]+$ ]] || insertions=0
        
        # 使用文件数量和插入行数估算
        if [ "$files_changed" -gt 0 ]; then
            size_bytes=$((files_changed * 5120 + insertions * 100))
        else
            # 默认估算为10KB
            size_bytes=10240
        fi
    fi
    
    # 确保返回的是数字
    [[ $size_bytes =~ ^[0-9]+$ ]] || size_bytes=0
    echo "$size_bytes"
}

# 获取单个提交的变更文件数量（用于估算）
get_commit_file_count() {
    local commit_hash=$1
    
    # 检查是否为初次提交
    local is_initial
    is_initial=$(is_initial_commit "$commit_hash")
    
    local file_count=0
    
    if [ "$is_initial" = "false" ]; then
        # 有父提交：获取变更文件数量
        file_count=$(git diff --name-only "${commit_hash}^" "$commit_hash" 2>/dev/null | wc -l | tr -d ' ')
        
        # 减去重命名文件数量（因为重命名不应该计入变更文件数量）
        local renamed_count
        renamed_count=$(git diff --name-status --diff-filter=R "${commit_hash}^" "$commit_hash" 2>/dev/null | wc -l | tr -d ' ')
        file_count=$((file_count - renamed_count))
        
        # 确保不会变成负数
        if [ $file_count -lt 0 ]; then
            file_count=0
        fi
    else
        # 初次提交：使用git show --stat获取文件数量
        local stat_info
        stat_info=$(parse_git_show_stat "$commit_hash")
        IFS='|' read -r files_changed insertions <<< "$stat_info"
        
        if [[ $files_changed =~ ^[0-9]+$ ]] && [ "$files_changed" -gt 0 ]; then
            file_count="$files_changed"
        else
            # 如果git show --stat没有获取到，尝试git ls-tree
            file_count=$(git ls-tree -r --name-only "$commit_hash" 2>/dev/null | wc -l | tr -d ' ')
        fi
    fi
    
    # 确保返回的是数字
    [[ $file_count =~ ^[0-9]+$ ]] || file_count=0
    echo "$file_count"
}

# 主函数
main() {
    # 检查是否请求帮助
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit 0
    fi
    
    # 获取要查询的提交次数
    local num_commits=${1:-$DEFAULT_COMMITS}
    
    # 验证参数是否为数字
    if ! [[ "$num_commits" =~ ^[0-9]+$ ]] || [ "$num_commits" -lt 1 ]; then
        echo -e "${RED}错误: 参数必须是大于0的数字${NC}"
        show_help
        exit 1
    fi
    
    # 检查是否在git仓库中
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo -e "${RED}错误: 当前目录不是git仓库${NC}"
        if $PAUSE_AFTER_COMPLETE; then
            echo -e "\n${YELLOW}按任意键退出...${NC}"
            read -n 1 -s -r
        fi
        exit 1
    fi
    
    echo -e "${CYAN}查询最近 ${NC}${num_commits}${CYAN} 次提交的变更体积...${NC}"
    echo ""
    
    # 获取最近的n次提交
    local total_bytes=0
    local commit_count=0
    
    # 使用数组存储结果
    declare -a commit_hashes
    declare -a commit_msgs
    declare -a commit_dates
    declare -a commit_sizes
    declare -a commit_formatted_sizes
    declare -a commit_file_counts
    declare -a commit_is_initial
    
    # 获取提交信息（包含日期）
    local commit_info
    commit_info=$(git log --format="%H|%s|%cd" --date=short -n "$num_commits" 2>/dev/null)
    
    if [[ -z "$commit_info" ]]; then
        echo -e "${RED}错误: 没有找到提交记录${NC}"
        if $PAUSE_AFTER_COMPLETE; then
            echo -e "\n${YELLOW}按任意键退出...${NC}"
            read -n 1 -s -r
        fi
        exit 1
    fi
    
    # 显示提交分析
    echo -e "${CYAN}提交分析:${NC}"
    echo -e "${NC}--------------------------------------------------------------------------------${NC}"
    
    # 遍历提交
    while IFS= read -r line; do
        # 解析提交信息
        IFS='|' read -r commit_hash commit_msg commit_date <<< "$line"
        
        # 跳过空行
        if [ -z "$commit_hash" ]; then
            continue
        fi
        
        # 检查是否为初次提交
        local is_initial
        is_initial=$(is_initial_commit "$commit_hash")
        
        # 显示当前正在分析的提交
        if [ "$is_initial" = "true" ]; then
            echo -e "${NC}分析提交 ${YELLOW}$((commit_count+1))${NC}/${num_commits}: ${PURPLE}${commit_hash:0:8}${ORANGE}*${NC} - ${commit_msg}"
            echo -e "  ${ORANGE}*这个提交是初次提交${NC}"
        else
            echo -e "${NC}分析提交 ${YELLOW}$((commit_count+1))${NC}/${num_commits}: ${PURPLE}${commit_hash:0:8}${NC} - ${commit_msg}"
        fi
        
        # 先获取变更文件数量
        local file_count
        file_count=$(get_commit_file_count "$commit_hash")
        
        # 确保file_count是数字
        [[ $file_count =~ ^[0-9]+$ ]] || file_count=0
        
        # 根据文件数量选择计算方法
        local size_bytes=0
        
        if [ "$file_count" -le 50 ]; then
            # 文件较少，使用准确方法
            size_bytes=$(get_commit_changed_size_accurate "$commit_hash")
        else
            # 文件较多，使用快速方法
            echo -e "  ${CYAN}变更文件较多(${file_count}个)，使用快速估算...${NC}"
            size_bytes=$(get_commit_changed_size_fast "$commit_hash")
        fi
        
        # 确保size_bytes是数字（移除可能的换行符）
        size_bytes=$(echo "$size_bytes" | tr -d '\n')
        [[ $size_bytes =~ ^[0-9]+$ ]] || size_bytes=0
        
        # 格式化大小
        formatted_size=$(format_size "$size_bytes")
        
        # 存储结果
        commit_hashes[$commit_count]="$commit_hash"
        commit_msgs[$commit_count]="$commit_msg"
        commit_dates[$commit_count]="$commit_date"
        commit_sizes[$commit_count]="$size_bytes"
        commit_formatted_sizes[$commit_count]="$formatted_size"
        commit_file_counts[$commit_count]="$file_count"
        commit_is_initial[$commit_count]="$is_initial"
        
        # 累加总大小（使用安全加法）
        total_bytes=$(safe_add "$total_bytes" "$size_bytes")
        
        # 显示当前提交大小
        echo -e "  ${CYAN}变更文件数量: ${NC}${file_count}${CYAN} 个，变更体积: ${GREEN}$formatted_size${NC} ($size_bytes 字节)"
        echo ""
        
        # 增加计数
        commit_count=$((commit_count + 1))
        
        # 如果达到指定数量，停止
        if [ "$commit_count" -ge "$num_commits" ]; then
            break
        fi
        
    done <<< "$commit_info"
    
    echo -e "${NC}--------------------------------------------------------------------------------${NC}"
    echo ""
    
    # 如果没有找到任何提交
    if [ "$commit_count" -eq 0 ]; then
        echo -e "${RED}错误: 没有找到提交记录${NC}"
        if $PAUSE_AFTER_COMPLETE; then
            echo -e "\n${YELLOW}按任意键退出...${NC}"
            read -n 1 -s -r
        fi
        exit 1
    fi
    
    # 显示汇总表格
    echo -e "${CYAN}提交变更体积汇总:${NC}"
    echo -e "${NC}================================================================================${NC}"
    printf "${CYAN}%-4s %-14s %-14s %-12s %-20s %-15s${NC}\n" "序号" "日期" "提交哈希" "文件数" "变更体积" "提交信息"
    echo -e "${NC}--------------------------------------------------------------------------------${NC}"
    
    # 显示每个提交的信息
    for ((i=0; i<commit_count; i++)); do
        # 截断过长的信息
        short_hash="${commit_hashes[$i]:0:8}"
        short_msg="${commit_msgs[$i]}"
        if [ ${#short_msg} -gt 8 ]; then
            short_msg="${short_msg:0:8}..."
        fi
        
        # 如果是初次提交，在哈希值后面加橙色星号，并适当填充空格以保持对齐
        if [ "${commit_is_initial[$i]}" = "true" ]; then
            # 初次提交：哈希8位 + 星号1位，共9位，我们填充到12位（加3个空格）
            display_hash="${PURPLE}${short_hash}${ORANGE}*${NC}   "
        else
            # 非初次提交：哈希8位，填充到12位（加4个空格）
            display_hash="${PURPLE}${short_hash}${NC}    "
        fi
        
        # 打印表格行，注意哈希列已经是12位宽度了
        printf "${YELLOW}%-4s${NC} ${CYAN}%-12s${NC} ${display_hash} ${NC}%-7s${NC} ${GREEN}%-16s${NC} ${NC}%-15s${NC}\n" \
            "$((i+1))" "${commit_dates[$i]}" "${commit_file_counts[$i]}" "${commit_formatted_sizes[$i]}" "$short_msg"
    done
    
    echo -e "${NC}--------------------------------------------------------------------------------${NC}"
    
    # 显示总大小
    formatted_total=$(format_size "$total_bytes")
    echo -e "\n${CYAN}最近 ${NC}${commit_count}${CYAN} 次提交总变更体积: ${GREEN}$formatted_total${NC} ($total_bytes 字节)"
    
    # 显示平均大小
    if [ $commit_count -gt 0 ]; then
        avg_bytes=$((total_bytes / commit_count))
        formatted_avg=$(format_size "$avg_bytes")
        echo -e "${CYAN}平均每次提交变更体积: ${GREEN}$formatted_avg${NC}"
        
        # 计算平均每个文件的体积
        total_files=0
        for ((i=0; i<commit_count; i++)); do
            total_files=$((total_files + commit_file_counts[i]))
        done
        
        if [ $total_files -gt 0 ]; then
            avg_file_size=$((total_bytes / total_files))
            formatted_avg_file=$(format_size "$avg_file_size")
            echo -e "${CYAN}平均每个变更文件体积: ${GREEN}$formatted_avg_file${NC}"
            echo -e ""
        fi
    fi
    
    # 显示最大的提交
    if [ $commit_count -gt 0 ]; then
        max_size=0
        max_index=0
        for ((i=0; i<commit_count; i++)); do
            if [ "${commit_sizes[$i]}" -gt "$max_size" ]; then
                max_size=${commit_sizes[$i]}
                max_index=$i
            fi
        done
        
        # 如果是初次提交，在哈希值后面加橙色星号
        if [ "${commit_is_initial[$max_index]}" = "true" ]; then
            max_hash_display="${PURPLE}${commit_hashes[$max_index]:0:8}${ORANGE}*${NC}"
        else
            max_hash_display="${PURPLE}${commit_hashes[$max_index]:0:8}${NC}"
        fi
        
        echo -e "${CYAN}最大变更提交: ${YELLOW}$((max_index+1))${CYAN}. ${max_hash_display}${CYAN} (${commit_dates[$max_index]})${NC}"
        echo -e "${CYAN}变更文件数量: ${NC}${commit_file_counts[$max_index]}${CYAN}，变更体积: ${GREEN}${commit_formatted_sizes[$max_index]}${NC}"
        echo -e "${CYAN}提交信息: ${NC}${commit_msgs[$max_index]}${NC}"
        echo -e ""
    fi
    
    # 显示最小的提交
    if [ $commit_count -gt 1 ]; then
        min_size=${commit_sizes[0]}
        min_index=0
        for ((i=1; i<commit_count; i++)); do
            if [ "${commit_sizes[$i]}" -lt "$min_size" ]; then
                min_size=${commit_sizes[$i]}
                min_index=$i
            fi
        done
        
        # 如果是初次提交，在哈希值后面加橙色星号
        if [ "${commit_is_initial[$min_index]}" = "true" ]; then
            min_hash_display="${PURPLE}${commit_hashes[$min_index]:0:8}${ORANGE}*${NC}"
        else
            min_hash_display="${PURPLE}${commit_hashes[$min_index]:0:8}${NC}"
        fi
        
        echo -e "${CYAN}最小变更提交: ${YELLOW}$((min_index+1))${CYAN}. ${min_hash_display}${CYAN} (${commit_dates[$min_index]})${NC}"
        echo -e "${CYAN}变更文件数量: ${NC}${commit_file_counts[$min_index]}${CYAN}，变更体积: ${GREEN}${commit_formatted_sizes[$min_index]}${NC}"
        echo -e "${CYAN}提交信息: ${NC}${commit_msgs[$min_index]}${NC}"
        if [ "${commit_is_initial[$min_index]}" = "true" ]; then
            echo -e "${CYAN}备注: ${GREEN}这是初次提交${NC}"
        fi
    fi
    
    echo ""
    
    # 完成后暂停
    if $PAUSE_AFTER_COMPLETE; then
        echo -e "${YELLOW}按任意键退出...${NC}"
        read -n 1 -s -r
    fi
}

# 执行主函数，并处理参数
main "$@"