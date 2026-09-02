proc configure_wide_bram {name depth_a} {
    create_ip -name blk_mem_gen -vendor xilinx.com -library ip \
        -module_name $name
    set ip [get_ips $name]
    set_property -dict [list \
        CONFIG.Memory_Type {True_Dual_Port_RAM} \
        CONFIG.Use_Byte_Write_Enable {true} \
        CONFIG.Byte_Size {8} \
        CONFIG.Write_Width_A {32} \
        CONFIG.Read_Width_A {32} \
        CONFIG.Write_Depth_A $depth_a \
        CONFIG.Write_Width_B {128} \
        CONFIG.Read_Width_B {128} \
        CONFIG.Operating_Mode_A {READ_FIRST} \
        CONFIG.Operating_Mode_B {READ_FIRST} \
        CONFIG.Enable_A {Use_ENA_Pin} \
        CONFIG.Enable_B {Use_ENB_Pin} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
        CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
        CONFIG.Use_RSTA_Pin {false} \
        CONFIG.Use_RSTB_Pin {false} \
        CONFIG.Load_Init_File {false} \
    ] $ip
    generate_target all $ip
}

