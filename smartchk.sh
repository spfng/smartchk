#!/usr/bin/env bash
VERSION="25/03/2025"

# Цветовые константы для вывода
declare -A COLORS=(
    [RED]="\e[0;41m"
    [GREEN]="\e[30;42m"
    [YELLOW]="\e[30;43m"
    [RESET]="\e[0m"
)

# Проверка наличия smartctl
if ! command -v smartctl &>/dev/null; then
    echo "Error: smartctl command not found"
    exit 1
fi

# Глобальные переменные
DEBUG=0
HP=0
SERIALS=()
AGGREGATE_ERROR=0

# Функция вывода помощи
function show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -d, --debug       Enable debug mode
  -u, --update      Update the script from the remote repository
  -v, --version     Show script version
  -h, --help        Show this help message
  -hp, --hp         Check HP cciss devices
EOF
}

# Функция обработки аргументов командной строки
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--debug)
                DEBUG=1
                shift
                ;;
            -u|--update)
                update_script
                exit 0
                ;;
            -v|--version)
                echo "$VERSION"
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -hp|--hp)
                HP=1
                shift
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
}

# Функция обновления скрипта
function update_script() {
    echo "Updating script..."
    wget -O /usr/sbin/smartchk.sh https://raw.githubusercontent.com/spfng/smartchk/refs/heads/main/smartchk.sh
}

# Функция проверки SMART-состояния диска
function check_smart_status() {
    local device="$1"
    local output
    local serial
    local error=0

    # Получение SMART-данных
    output=$(smartctl -v 1,raw48:54 -v 7,raw48:54 -v 195,raw48:54 -a "$device" 2>/dev/null)

    # Извлечение серийного номера
    serial=$(echo "$output" | grep -E "Serial Number:|Serial number:" | awk '{print $NF}')
    if [[ -z "$serial" || " ${SERIALS[@]} " =~ " $serial " ]]; then
        return 0
    fi
    SERIALS+=("$serial")

    [[ $DEBUG -eq 1 ]] && echo -e "${COLORS[GREEN]}Scanning $device (Serial: $serial)${COLORS[RESET]}"

    # Проверка износа SSD
    check_wear_level "$device" "$output" && error=$((error + 1))

    # Проверка перераспределённых секторов
    check_reallocated_sectors "$device" "$output" && error=$((error + 1))

    # Проверка ошибок Offline_Uncorrectable
    check_offline_uncorrectable "$device" "$output" && error=$((error + 1))

    # Проверка SAS ошибок
    check_sas_errors "$device" "$output" && error=$((error + 1))

    return $error
}

# Проверка износа SSD
function check_wear_level() {
    local device="$1"
    local output="$2"
    local wear_level
    wear_level=$(echo "$output" | grep -Ei "177 Wear_Leveling|231 SSD_Life_Left|^173 Un|233 Media_Wearout_" | awk '{print $4}' | sed 's/^0*//' | head -n1)
    if [[ $wear_level -lt 20 && $wear_level -gt 0 ]]; then
        echo -e "${COLORS[RED]}$device is at ${wear_level}% SSD wear${COLORS[RESET]}"
        return 1
    elif [[ $DEBUG -eq 1 && $wear_level -gt 0 ]]; then
        echo -e "${COLORS[GREEN]}$device is at ${wear_level}% SSD wear${COLORS[RESET]}"
    fi
    return 0
}

# Проверка перераспределённых секторов
function check_reallocated_sectors() {
    local device="$1"
    local output="$2"
    local sectors
    sectors=$(echo "$output" | grep "Reallocated_Sector" | awk '{print $10}')
    if [[ $sectors -gt 0 ]]; then
        echo -e "${COLORS[RED]}$device has $sectors Sector Errors${COLORS[RESET]}"
        return 1
    elif [[ $DEBUG -eq 1 && $sectors =~ ^[0-9]+$ ]]; then
        echo -e "${COLORS[GREEN]}$device has $sectors Sector Errors${COLORS[RESET]}"
    fi
    return 0
}

# Проверка ошибок Offline_Uncorrectable
function check_offline_uncorrectable() {
    local device="$1"
    local output="$2"
    local errors
    errors=$(echo "$output" | grep "Offline_Uncorrectable" | awk '{print $10}')
    if [[ $errors -gt 0 ]]; then
        echo -e "${COLORS[RED]}$device has $errors Offline Uncorrectable Errors${COLORS[RESET]}"
        return 1
    elif [[ $DEBUG -eq 1 && $errors =~ ^[0-9]+$ ]]; then
        echo -e "${COLORS[GREEN]}$device has $errors Offline Uncorrectable Errors${COLORS[RESET]}"
    fi
    return 0
}

# Проверка SAS ошибок
function check_sas_errors() {
    local device="$1"
    local output="$2"
    local read_errors write_errors verify_errors
    read_errors=$(echo "$output" | grep -E "read:" | awk '{print $8}')
    write_errors=$(echo "$output" | grep -E "write:" | awk '{print $8}')
    verify_errors=$(echo "$output" | grep -E "verify:" | awk '{print $8}')

    if [[ $read_errors -gt 0 || $write_errors -gt 0 || $verify_errors -gt 0 ]]; then
        echo -e "${COLORS[RED]}$device has SAS errors: Read=$read_errors, Write=$write_errors, Verify=$verify_errors${COLORS[RESET]}"
        return 1
    elif [[ $DEBUG -eq 1 && ($read_errors =~ ^[0-9]+$ || $write_errors =~ ^[0-9]+$ || $verify_errors =~ ^[0-9]+$) ]]; then
        echo -e "${COLORS[GREEN]}$device has SAS errors: Read=$read_errors, Write=$write_errors, Verify=$verify_errors${COLORS[RESET]}"
    fi
    return 0
}

# Основная функция сканирования дисков
function scan_disks() {
    local devices
    devices=$(find /dev -type b -name 'sd*' | egrep '^(\/)dev(\/)sd[a-z]$')
    for device in $devices; do
        check_smart_status "$device"
        AGGREGATE_ERROR=$((AGGREGATE_ERROR + $?))
    done
}

# Главная функция
function main() {
    parse_args "$@"
    scan_disks

    if [[ $AGGREGATE_ERROR -gt 0 ]]; then
        echo -e "${COLORS[RED]}$AGGREGATE_ERROR Errors were found${COLORS[RESET]}"
        exit $AGGREGATE_ERROR
    else
        echo -e "${COLORS[GREEN]}No errors were found${COLORS[RESET]}"
        exit 0
    fi
}

main "$@"
