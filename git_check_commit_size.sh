#!/bin/bash

# 脚本名称: git_commit_size.sh
# 功能: 查询最近n次提交的实际变更文件体积大小
# 改进版：准确计算每次提交的变更文件大小，优化速度

# 设置默认提交次数
DEFAULT_COMMITS=5
PAUSE_AFTER_COMPLETE=true  # 完成后是否暂停

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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

# 获取单个提交的变更文件大小（简化但更准确的方法）
get_commit_changed_size_accurate() {
    local commit_hash=$1
    local size_bytes=0
    
    # 获取父提交
    local parent_commit
    parent_commit=$(git rev-parse "$commit_hash"^ 2>/dev/null || echo "")
    
    if [ -n "$parent_commit" ]; then
        # 有父提交：使用git show --stat并分析实际对象变化
        # 这个方法更简单：检查本次提交实际创建的新对象大小
        
        # 获取本次提交创建的所有新对象（blob）
        # 使用git rev-list获取本次提交引入的所有对象
        local new_objects
        new_objects=$(git rev-list --objects "$parent_commit".."$commit_hash" 2>/dev/null | \
                     while read -r hash name; do
                         # 只处理blob对象
                         local obj_type
                         obj_type=$(git cat-file -t "$hash" 2>/dev/null)
                         if [ "$obj_type" = "blob" ]; then
                             echo "$hash"
                         fi
                     done)
        
        # 去重并计算总大小
        if [ -n "$new_objects" ]; then
            # 对对象哈希排序去重
            local unique_objects
            unique_objects=$(echo "$new_objects" | sort | uniq)
            
            # 计算所有唯一对象的总大小
            while IFS= read -r obj_hash; do
                if [ -n "$obj_hash" ]; then
                    local obj_size
                    obj_size=$(git cat-file -s "$obj_hash" 2>/dev/null || echo "0")
                    size_bytes=$((size_bytes + obj_size))
                fi
            done <<< "$unique_objects"
        fi
    else
        # 初始提交：获取所有文件的大小
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local file_size
                file_size=$(echo "$line" | awk '{print $4}')
                size_bytes=$((size_bytes + file_size))
            fi
        done < <(git ls-tree -r -l "$commit_hash" 2>/dev/null)
    fi
    
    echo "${size_bytes:-0}"
}

# 获取单个提交的变更文件大小（快速方法）
get_commit_changed_size_fast() {
    local commit_hash=$1
    local size_bytes=0
    
    # 获取父提交
    local parent_commit
    parent_commit=$(git rev-parse "$commit_hash"^ 2>/dev/null || echo "")
    
    if [ -n "$parent_commit" ]; then
        # 有父提交：使用git diff --stat估算
        local stat_output
        stat_output=$(git diff --shortstat "$parent_commit" "$commit_hash" 2>/dev/null)
        
        if [ -n "$stat_output" ]; then
            # 解析例如: 3 files changed, 150 insertions(+), 20 deletions(-)
            local files_changed
            local insertions
            files_changed=$(echo "$stat_output" | grep -oE '[0-9]+ files?' | grep -oE '[0-9]+' || echo "0")
            insertions=$(echo "$stat_output" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
            
            # 简单估算：假设平均每行100字节，每个文件增加50行
            if [ "$files_changed" -gt 0 ]; then
                # 基于文件数量和插入行数估算
                size_bytes=$((files_changed * 5120 + insertions * 100))  # 每个文件5KB + 每行100字节
            fi
        fi
    else
        # 初始提交：简单估算为10KB
        size_bytes=10240
    fi
    
    echo "${size_bytes:-0}"
}

# 获取单个提交的变更文件数量（用于估算）
get_commit_file_count() {
    local commit_hash=$1
    
    # 获取父提交
    local parent_commit
    parent_commit=$(git rev-parse "$commit_hash"^ 2>/dev/null || echo "")
    
    if [ -n "$parent_commit" ]; then
        # 有父提交：获取变更文件数量
        git diff --name-only "$parent_commit" "$commit_hash" 2>/dev/null | wc -l | tr -d ' '
    else
        # 初始提交：获取所有文件数量
        git ls-tree -r --name-only "$commit_hash" 2>/dev/null | wc -l | tr -d ' '
    fi
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
    
    echo -e "${CYAN}查询最近 ${NC}${num_commits}${CYAN} 次提交的变更文件体积...${NC}"
    
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
        
        # 显示当前正在分析的提交
        echo -e "${NC}分析提交 ${YELLOW}$((commit_count+1))${PURPLE}/${num_commits}: ${PURPLE}${commit_hash:0:8}${NC} - ${commit_msg}"
        
        # 先获取变更文件数量
        local file_count
        file_count=$(get_commit_file_count "$commit_hash")
        
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
        
        # 格式化大小
        formatted_size=$(format_size "$size_bytes")
        
        # 存储结果
        commit_hashes[$commit_count]="$commit_hash"
        commit_msgs[$commit_count]="$commit_msg"
        commit_dates[$commit_count]="$commit_date"
        commit_sizes[$commit_count]="$size_bytes"
        commit_formatted_sizes[$commit_count]="$formatted_size"
        commit_file_counts[$commit_count]="$file_count"
        
        # 累加总大小
        total_bytes=$((total_bytes + size_bytes))
        
        # 显示当前提交大小
        echo -e "  ${CYAN}变更文件数量: ${GREEN}${file_count}${CYAN} 个，变更体积: ${GREEN}$formatted_size${NC} ($size_bytes 字节)"
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
        
        printf "${YELLOW}%-4s${NC} ${CYAN}%-12s${NC} ${PURPLE}%-12s${NC} ${NC}%-8s${NC} ${GREEN}%-15s${NC} ${WHITE}%-15s${NC}\n" \
            "$((i+1))" "${commit_dates[$i]}" "$short_hash" "${commit_file_counts[$i]}" "${commit_formatted_sizes[$i]}" "$short_msg"
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
        
        echo -e "${CYAN}最大变更提交: ${YELLOW}$((max_index+1))${CYAN}. ${PURPLE}${commit_hashes[$max_index]:0:8}${CYAN} (${commit_dates[$max_index]})${NC}"
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
        
        echo -e "${CYAN}最小变更提交: ${YELLOW}$((min_index+1))${CYAN}. ${PURPLE}${commit_hashes[$min_index]:0:8}${CYAN} (${commit_dates[$min_index]})${NC}"
        echo -e "${CYAN}变更文件数量: ${NC}${commit_file_counts[$min_index]}${CYAN}，变更体积: ${GREEN}${commit_formatted_sizes[$min_index]}${NC}"
        echo -e "${CYAN}提交信息: ${NC}${commit_msgs[$min_index]}${NC}"
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