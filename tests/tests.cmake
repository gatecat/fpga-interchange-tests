function(add_generic_test)
    # ~~~
    # add_generic_test(
    #    name <name>
    #    board_list <board_list>
    #    sources <sources list>
    #    [absolute_sources <sources list>]
    #    [tcl <tcl>]
    #    [top <top name>]
    #    [techmap <techmap file>]
    #    [testbench]
    # )
    #
    # Generates targets to run desired tests
    #
    # Arguments:
    #   - name: test name. This must be unique and no other tests with the same
    #           name should exist
    #   - board_list: list of boards, one for each test
    #   - tcl: tcl script used for synthesis
    #   - sources: list of HDL sources
    #   - absoulute_sources (optional): list of sources with an absoulute path.
    #   - top (optional): name of the top level module.
    #                     If not provided, "top" is assigned as top level module
    #   - techmap (optional): techmap file used during synthesis
    #   - testbench (optional): verilog testbench to verify the correctness of the design
    #                           generated by fasm2bels
    #
    # Targets generated:
    #   - <arch>-<name>-<board>-json     : synthesis output
    #   - <arch>-<name>-<board>-netlist  : logical interchange netlist
    #   - <arch>-<name>-<board>-phys     : physical interchange netlist
    #   - <arch>-<name>-<board>-fasm     : fasm file

    set(options)
    set(oneValueArgs name tcl top techmap testbench)
    set(multiValueArgs board_list sources absolute_sources)

    cmake_parse_arguments(
        add_generic_test
        "${options}"
        "${oneValueArgs}"
        "${multiValueArgs}"
        ${ARGN}
    )

    set(name ${add_generic_test_name})
    set(top ${add_generic_test_top})
    set(testbench ${add_generic_test_testbench})
    set(techmap ${add_generic_test_techmap})
    set(tcl ${add_generic_test_tcl})

    set(sources)
    foreach(source ${add_generic_test_sources})
        list(APPEND sources ${CMAKE_CURRENT_SOURCE_DIR}/${source})
    endforeach()
    foreach(source ${add_generic_test_absolute_sources})
        list(APPEND sources ${source})
    endforeach()

    if (DEFINED techmap)
        set(techmap ${CMAKE_CURRENT_SOURCE_DIR}/${add_generic_test_techmap})
    endif()

    if (NOT DEFINED top)
        # Setting default top value
        set(top "top")
    endif()

    set(quiet_cmd ${CMAKE_SOURCE_DIR}/utils/quiet_cmd.sh)

    get_target_property(YOSYS programs YOSYS)
    get_target_property(NEXTPNR_FPGA_INTERCHANGE programs NEXTPNR_FPGA_INTERCHANGE)
    get_target_property(PYTHON3 programs PYTHON3)

    foreach(board ${add_generic_test_board_list})
        # Get board properties
        get_property(device_family TARGET board-${board} PROPERTY DEVICE_FAMILY)
        get_property(device TARGET board-${board} PROPERTY DEVICE)
        get_property(package TARGET board-${board} PROPERTY PACKAGE)
        get_property(part TARGET board-${board} PROPERTY PART)
        get_property(arch TARGET board-${board} PROPERTY ARCH)

        set(test_name "${name}-${board}")
        set(xdc ${CMAKE_CURRENT_SOURCE_DIR}/${board}.xdc)
        set(device_loc ${CMAKE_BINARY_DIR}/devices/${device}/${device}.device)
        set(chipdb_loc ${CMAKE_BINARY_DIR}/devices/${device}/${device}.bin)

        set(output_dir ${CMAKE_CURRENT_BINARY_DIR}/${board})
        add_custom_command(
            OUTPUT ${output_dir}
            COMMAND ${CMAKE_COMMAND} -E make_directory ${output_dir}
        )

        add_custom_target(${arch}-${test_name}-output-dir DEPENDS ${output_dir})

        # Synthesis
        set(synth_tcl "${CMAKE_SOURCE_DIR}/tests/common/synth_${arch}.tcl")
        if (DEFINED tcl)
            set(synth_tcl ${CMAKE_CURRENT_SOURCE_DIR}/${add_${arch}_test_tcl})
        endif()

        set(synth_json ${output_dir}/${name}.json)
        set(synth_log ${output_dir}/${name}.synth.log)
        set(synth_verilog ${output_dir}/${name}.synth.v)
        add_custom_command(
            OUTPUT ${synth_json}
            COMMAND ${CMAKE_COMMAND} -E env
                SOURCES="${sources}"
                OUT_JSON=${synth_json}
                OUT_VERILOG=${synth_verilog}
                TECHMAP=${techmap}
                ${quiet_cmd}
                ${YOSYS} -c ${synth_tcl} -l ${synth_log}
            DEPENDS
                ${sources}
                ${techmap}
                ${synth_tcl}
                ${arch}-${test_name}-output-dir
        )

        add_custom_target(${arch}-${test_name}-json DEPENDS ${synth_json})

        set(simlib_dir "")
        if(${arch} STREQUAL "xc7")
            set(simlib_dir ${XILINX_UNISIM_DIR})
        endif()
        if(DEFINED testbench AND NOT ${simlib_dir} STREQUAL "")
            add_simulation_test(
                name ${name}
                board ${board}
                sources ${sources}
                deps ${arch}-${test_name}-output-dir
                testbench ${testbench}
                simlib_dir ${simlib_dir}
                extra_libs ${simlib_dir}/../glbl.v
            )

            add_simulation_test(
                name post-synth-${name}
                board ${board}
                sources ${synth_verilog}
                deps ${arch}-${test_name}-json
                testbench ${testbench}
                simlib_dir ${simlib_dir}
                extra_libs ${simlib_dir}/../glbl.v
            )
        endif()

        # Logical netlist
        set(netlist ${output_dir}/${name}.netlist)
        add_custom_command(
            OUTPUT ${netlist}
            COMMAND ${CMAKE_COMMAND} -E env
                ${quiet_cmd}
                ${PYTHON3} -mfpga_interchange.yosys_json
                    --schema_dir ${INTERCHANGE_SCHEMA_PATH}
                    --device ${device_loc}
                    --top ${top}
                    ${synth_json}
                    ${netlist}
            DEPENDS
                ${arch}-${test_name}-json
                chipdb-${device}-bin
                ${device_loc}
                ${synth_json}
        )

        add_custom_target(${arch}-${test_name}-netlist DEPENDS ${netlist})

        # Physical netlist
        set(phys ${output_dir}/${name}.phys)
        set(phys_log ${output_dir}/${name}.phys.log)
        add_custom_command(
            OUTPUT ${phys}
            COMMAND
                ${quiet_cmd}
                ${NEXTPNR_FPGA_INTERCHANGE}
                    --chipdb ${chipdb_loc}
                    --xdc ${xdc}
                    --netlist ${netlist}
                    --phys ${phys}
                    --package ${package}
                    --log ${phys_log}
            DEPENDS
                ${arch}-${test_name}-netlist
                ${xdc}
                chipdb-${device}-bin
                ${chipdb_loc}
                ${netlist}
        )

        # Physical Netlist YAML
        set(phys_yaml ${output_dir}/${name}.phys.yaml)
        add_custom_command(
            OUTPUT ${phys_yaml}
            COMMAND
                ${PYTHON3} -mfpga_interchange.convert
                    --schema_dir ${INTERCHANGE_SCHEMA_PATH}
                    --schema physical
                    --input_format capnp
                    --output_format yaml
                    ${phys}
                    ${phys_yaml}
            DEPENDS
                ${arch}-${test_name}-phys
                ${phys}
        )

        add_custom_target(${arch}-${test_name}-phys DEPENDS ${phys})
        add_custom_target(${arch}-${test_name}-phys-yaml DEPENDS ${phys_yaml})

        # Output FASM target
        set(fasm ${output_dir}/${name}.fasm)
        add_custom_command(
            OUTPUT ${fasm}
            COMMAND ${CMAKE_COMMAND} -E env
                ${quiet_cmd}
                ${PYTHON3} -mfpga_interchange.fasm_generator
                    --schema_dir ${INTERCHANGE_SCHEMA_PATH}
                    --family ${arch}
                    ${device_loc}
                    ${netlist}
                    ${phys}
                    ${fasm}
            DEPENDS
                ${device_target}
                ${arch}-${test_name}-netlist
                ${arch}-${test_name}-phys
                ${netlist}
                ${phys}
        )

        add_custom_target(${arch}-${test_name}-fasm DEPENDS ${fasm})
        add_dependencies(all-tests ${arch}-${test_name}-fasm)
        add_dependencies(all-${device}-tests ${arch}-${test_name}-fasm)

        if(${arch} STREQUAL "xc7")
            add_xc7_test(
                name ${name}
                board ${board}
                sources ${sources}
                netlist ${netlist}
                phys ${phys}
                fasm ${fasm}
                top ${top}
            )
        endif()
    endforeach()
endfunction()

function(add_simulation_test)
    # ~~~
    # add_simulation_test(
    #    name <name>
    #    board <board>
    #    testbench <testbench>
    #    deps
    #    [extra_libs <extra libraries>]
    #    [simlib_dir <simulation lib directory>]
    # )
    #
    # Generates targets to run desired simulation tests.
    #
    # This function should not be called directly, but within another test function.
    #
    # Arguments:
    #   - name: test name. This must be unique and no other tests with the same
    #           name should exist
    #   - board: board name. This is used to get the output directory
    #   - testbench: verilog testbench file that instantiates the DUT and performs
    #                basic tests
    #   - deps: dependencies to be met prior to running the simulation test
    #   - extra_libs (optional): verilog libraires for vendor-specific cells
    #   - simlib_dir (optional): simulation library directory
    #
    # Targets generated:
    #   - sim-test-${test}-${board}-vvp : generates the VVP and VCD files
    #   - sim-test-${test}-${board}     : runs VVP

    set(options)
    set(oneValueArgs board name testbench deps simlib_dir)
    set(multiValueArgs sources extra_libs)

    cmake_parse_arguments(
        add_simulation_test
        "${options}"
        "${oneValueArgs}"
        "${multiValueArgs}"
        ${ARGN}
    )

    set(name ${add_simulation_test_name})
    set(board ${add_simulation_test_board})
    set(sources ${add_simulation_test_sources})
    set(deps ${add_simulation_test_deps})
    set(extra_libs ${add_simulation_test_extra_libs})
    set(simlib_dir ${add_simulation_test_simlib_dir})
    set(testbench ${CMAKE_CURRENT_SOURCE_DIR}/${add_simulation_test_testbench})

    set(test_name "${name}-${board}")

    get_target_property(VVP programs VVP)
    get_target_property(IVERILOG programs IVERILOG)

    set(output_dir ${CMAKE_CURRENT_BINARY_DIR}/${board})

    set(utils_dir ${CMAKE_SOURCE_DIR}/utils)
    set(quiet_cmd ${utils_dir}/quiet_cmd.sh)

    set(simlib_dir_opt "")
    if(DEFINED simlib_dir)
        set(simlib_dir_opt "-y${simlib_dir}")
    endif()

    set(vvp ${name}.vvp)
    set(vvp_path ${output_dir}/${vvp})
    add_custom_command(
        OUTPUT ${vvp_path}
        COMMAND
            ${quiet_cmd}
            ${IVERILOG}
                -v
                -I ${utils_dir}
                -DVCD=${output_dir}/${name}.vcd
                -o ${vvp}
                ${simlib_dir_opt}
                ${extra_libs}
                ${sources}
                ${testbench}
        DEPENDS
            ${IVERILOG}
            ${deps}
            ${sources}
            ${testbench}
        WORKING_DIRECTORY
            ${output_dir}
    )

    add_custom_target(sim-test-${test_name}-vvp DEPENDS ${vvp_path})

    add_custom_target(
        sim-test-${test_name}
        COMMAND
            ${quiet_cmd}
            ${VVP}
                -v
                -N
                ${vvp_path}
        DEPENDS
            ${VVP}
            sim-test-${test_name}-vvp
    )

    add_dependencies(all-simulation-tests sim-test-${test_name})
    add_dependencies(all-${device}-simulation-tests sim-test-${test_name})
endfunction()
