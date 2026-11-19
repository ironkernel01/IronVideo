# SPDX-License-Identifier: GPL-2.0-only
# Reset and the UART RX input are asynchronous to sys_clock.
set_false_path -from [get_ports {resetn uart_rx}]
set_max_delay 10.0 -to [get_ports uart_tx]
set_min_delay 0.0 -to [get_ports uart_tx]
set_max_delay 5.0 -to [get_ports {hdmi_clk_p hdmi_clk_n hdmi_data_p[*] hdmi_data_n[*]}]
set_min_delay 0.0 -to [get_ports {hdmi_clk_p hdmi_clk_n hdmi_data_p[*] hdmi_data_n[*]}]
