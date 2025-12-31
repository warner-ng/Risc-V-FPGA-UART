# ========================================
# Zynq 7021 约束文件
# 基于 AXI UART 16550 的 RISC-V 系统
# ========================================

# ========================================
# 系统时钟和复位（Block Design 项目）
# ========================================
# 注意：在 Block Design 中，时钟和复位通常由 PS 提供
# 
# 如果你使用 Block Design（PS + AXI UART 16550）：
#   - 时钟由 PS 的 FCLK_CLK0 提供，不需要外部时钟约束
#   - 复位由 PS 提供，不需要外部复位约束
#   - 下面的约束应该注释掉或删除
#
# 如果你使用纯 RTL 项目（不用 PS）：
#   - 需要下面的时钟和复位约束
#   - 取消注释即可

# 外部时钟（仅纯 RTL 项目需要）
# set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]
# create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports sys_clk]

# 外部复位（仅纯 RTL 项目需要）
# set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

# ========================================
# PL UART 引脚（连接到外部 USB-UART 芯片）
# ========================================
# sin_0 是 UART 接收（RX）
# sout_0 是 UART 发送（TX）
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports sin_0]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports sout_0]

# ========================================
# 可选：LED 指示灯（用于调试）
# ========================================
# 如果你的设计中有 LED 输出，添加以下约束
# 请根据你的板子原理图修改引脚编号
# set_property -dict {PACKAGE_PIN [你的LED引脚] IOSTANDARD LVCMOS33} [get_ports {led[0]}]
# set_property -dict {PACKAGE_PIN [你的LED引脚] IOSTANDARD LVCMOS33} [get_ports {led[1]}]

# ========================================
# 注意事项
# ========================================
# 1. PS 端的引脚（DDR、ENET、PS UART 等）不需要在这里约束
#    它们在 Block Design 中的 PS 配置里已经定义
#
# 2. 上述引脚编号（U18、N16、K14、M15）是正点原子领航者板子的
#    如果你用的是其他板子，务必查看原理图修改
#
# 3. sys_clk 的频率要与 Block Design 中 PS 提供给 PL 的时钟匹配
#    通常 PS 的 FCLK_CLK0 输出 50MHz 或 100MHz
