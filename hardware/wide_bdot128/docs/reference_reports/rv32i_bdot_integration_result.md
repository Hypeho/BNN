# RV32I Blocking BDOT 및 CDC 통합 결과

> 상태: 이 문서의 CDC 부분은 이전 dual-clock 구현 기록이다. 현재 CPU/BDOT 35 MHz
> 직접 통합 결과는 `cpu_integrated_bdot35_implementation_result.md`를 따른다.

- 검증일: 2026-08-17
- 상태: PASS
- CPU clock 시험값: 약 35 MHz
- Accelerator clock 시험값: 약 105 MHz

## ISA encoding

Wide-BDOT은 custom-1 opcode `0x2b`, `funct7=0`을 사용한다.

| Instruction | funct3 | 의미 |
|---|---:|---|
| `BCFG_LENGTH rs1` | `000` | `BNN_LENGTH <- x[rs1]` |
| `BDOT rd,rs1,rs2` | `001` | Activation/Weight base로 BDOT 실행 후 rd write |

CPU 통합 전 팀 공용 opcode allocation과 다시 대조해야 한다.

## 구현 항목

- `bdot_cpu_control.v`
  - IDLE/WAIT/COMMIT state
  - BDOT decode 즉시 PC hold
  - WAIT 중 normal RegWrite/MemWrite 억제
  - operand, bit length 및 rd latch
  - 완료 시 register write-back 1회
  - error response 시 register write 억제
- `bdot_cdc_bridge.v`
  - CPU→accelerator request toggle synchronizer
  - transaction 동안 operand bundled-data hold
  - accelerator→CPU response toggle synchronizer
  - result/error bundled-data hold
- `rv32i_cpu.v`
  - 기준 XPC32 CPU를 새 작업본으로 복제
  - PC enable 추가
  - BDOT commit rd/data mux 추가
  - memory side-effect suppression 연결

## Dual-clock 통합시험

다음 전체 경로를 연결했다.

```text
BCFG/BDOT decode
  -> CPU blocking control
  -> request CDC
  -> BDOT128
  -> Activation/Weight wide memory
  -> result CDC
  -> CPU register commit
```

결과:

```text
TB PASS: bdot_cpu_control starts=2 errors=0
TB PASS: bdot_dual_clock bits=784 result=385 cpu_wait_cycles=15 errors=0
```

## 실제 RV32I program 통합시험

시험 프로그램:

```text
addi x1,x0,784
bcfg_len x1
addi x3,x0,1024
bdot x5,x0,x3
sw x5,0(x0)
jal x0,0
```

결과:

```text
TB PASS: rv32i_bdot result=411 pc_hold_cycles=16 starts=1 total_cycles=19
```

- BDOT PC가 transaction 동안 유지됐다.
- accelerator start는 한 번만 발생했다.
- 결과가 x5에 한 번 write-back됐다.
- 다음 SW가 x5의 결과 411을 정상 저장했다.

## 기존 기능 회귀

| 시험 | 결과 | 기준과 비교 |
|---|---|---|
| RV32I base | PASS, 136 cycles | 동일 |
| XPC32 smoke | PASS, 23 cycles | 동일 |
| eBNN | PASS, 4,749,274 cycles, prediction 5 | 동일 |

## 현재 한계

- CPU와 accelerator 사이 toggle CDC는 RTL 기능검증 단계이며 FPGA CDC report와
  physical timing 검증이 필요하다.
- bundled-data operand/result bus는 toggle이 도착할 때까지 source register가
  유지된다는 protocol에 의존한다.
- `ASYNC_REG` attribute와 timing constraint는 Vivado 통합 단계에서 추가한다.
- 이 문서는 CPU/CDC 단위 통합 당시 결과이다. 이후 wide-aligned image와 FINN LFC
  전체 추론을 완료했다.
- 최신 결과와 break-even은 `lfc_bdot128_rtl_result.md`를 기준으로 한다.
- 실제 400 KiB BMG 포함 post-route 결과는 `wide_bdot_core_vivado_result.md`를
  기준으로 한다.

## 이후 완료 및 다음 단계

Block Memory Generator wrapper와 실제 BMG 등가검증, `ASYNC_REG`/CDC timing
constraint, Ultra96 part OOC 합성·배치배선은 모두 완료했다. 최신 수치는
`wide_bdot_core_vivado_result.md`에 있다. 남은 단계는 다음과 같다.

1. Ultra96 PS/AXI Block Design과 Instruction/Data BRAM을 통합한다.
2. bitstream/XSA 및 PS loader를 생성한다.
3. FPGA 실행시간·전력을 측정해 energy/inference를 계산한다.
