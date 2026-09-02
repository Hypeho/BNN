# Toolchain 확인 결과

확인일은 2026-09-02임.

## Vivado 2019.1 / XSim

| Tool | Executable | 확인 결과 |
|---|---|---|
| Vivado | `C:\Xilinx\Vivado\2019.1\bin\vivado.bat` | Vivado v2019.1 64-bit가 실행 가능함. |
| xvlog | `C:\Xilinx\Vivado\2019.1\bin\xvlog.bat` | Vivado Simulator 2019.1이 실행 가능함. |
| xelab | `C:\Xilinx\Vivado\2019.1\bin\xelab.bat` | Vivado Simulator 2019.1이 실행 가능함. |
| xsim | `C:\Xilinx\Vivado\2019.1\bin\xsim.bat` | Vivado Simulator 2019.1이 실행 가능함. |

- 최종 공식 RTL regression에는 위 세 XSim executable을 사용함.
- 다른 Vivado version으로 대체하지 않음.

## Python

- Executable은 `C:\Users\AERO\AppData\Local\Programs\Python\Python312\python.exe`임.
- Version은 Python 3.12.1임.
- 기본 PATH에는 등록되지 않아 runner에서 absolute path 또는 process-local PATH를 사용해야 함.

## RISC-V Toolchain

- Tool root는 `C:\Users\AERO\Downloads\project\학부연구생\RV32I_Single_Cycle_CPU\rv32imac (source)\bin`임.
- `riscv32-unknown-elf-gcc.exe`는 GCC 10.1.0임.
- `riscv32-unknown-elf-objcopy.exe`는 GNU Binutils 2.34임.
- 기본 PATH에는 등록되지 않아 runner에서 absolute path 또는 process-local PATH를 사용해야 함.

## Git / GitHub CLI

- Git executable은 `C:\Program Files\Git\cmd\git.exe`임.
- Git version은 2.44.0.windows.1임.
- GitHub CLI executable은 `C:\Program Files\GitHub CLI\gh.exe`임.
- GitHub CLI version은 2.93.0임.
- 현재 단계에서는 clone, pull, commit, push, remote repository 생성을 수행하지 않음.

## WSL / Icarus Verilog

- WSL2의 Ubuntu-22.04 배포판을 사용할 수 있음.
- Icarus Verilog executable은 `/usr/local/bin/iverilog`임.
- Icarus Verilog version은 13.0 development build임.
- vvp executable은 `/usr/local/bin/vvp`이며 동일한 13.0 runtime임.
- Icarus는 debug 또는 XSim 결과 cross-check에만 사용함.

