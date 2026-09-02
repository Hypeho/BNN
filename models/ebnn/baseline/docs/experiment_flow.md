# 260624 eBNN Binary MNIST 실험 흐름

## 목표

`TinyML/BNN/ebnn`의 `binary_mnist` 예제를 RV32I bare-metal 이미지로 빌드하고,
Ultra96 PS가 AXI BRAM에 `imem`/`dmem`을 적재한 뒤 PL의 RV32I 코어에서
추론을 실행한다.

## 구성

```text
common/
  ebnn.h
  binary_mnist.h
  binary_mnist_data.h
PC/
  ebnn_binary_mnist_host_ref.c
RISC-V/
  crt0.S
  custom_memory_ebnn.ld
  main_ebnn_binary_mnist_rv32i.c
script/
  build_ebnn_pc.sh
  build_ebnn_rv32i.sh
Vitis/
  helloworld.c
  inst_array.c
  data_array.c
```

## 실행

PC golden:

```bash
./script/build_ebnn_pc.sh
```

RV32I 이미지:

```bash
./script/build_ebnn_rv32i.sh
```

`build_ebnn_rv32i.sh`는 다음 산출물을 만든다.

```text
build_rv32i/main_ebnn_binary_mnist_rv32i.elf
build_rv32i/main_ebnn_binary_mnist_rv32i.asm
build_rv32i/imem.hex
build_rv32i/dmem.hex
Vitis/inst_array.c
Vitis/data_array.c
```

## Mailbox

RV32I는 DMEM base `0x20000000`의 mailbox에 결과를 기록한다.

```text
word 0  status
word 1  sample_count
word 2  correct_count
word 3  first_fail_index
word 4  prediction_checksum
word 5  last_predicted
word 6  last_expected
word 7  input_bytes
word 8  class_count
word 16 prediction[0]
word 36 expected[0]
```

상태값:

```text
0x100 started
0x110 input ready
0x120 inference done
0x001 ok
```

## 현재 golden

`binary_mnist` 내장 20개 샘플 기준:

```text
predictions=[5,0,4,1,9,2,1,3,1,4,3,5,3,6,1,7,2,8,6,7]
correct=19
first_fail=19
checksum=0x17e7ff6f
```

## Ultra96 실행 결과

Vitis PS app에서 `Vitis/inst_array.c`, `Vitis/data_array.c`를 AXI BRAM에
적재한 뒤 RV32I reset을 해제해 실행했다.

```text
inst_words=3289
data_words=815
samples=20
correct=19
first_fail=19
checksum=0x17E7FF6F
predictions=[5,0,4,1,9,2,1,3,1,4,3,5,3,6,1,7,2,8,6,7]
expected=[5,0,4,1,9,2,1,3,1,4,3,5,3,6,1,7,2,8,6,9]
total_time=2713.344 ms
approx_cycles=94,967,040 @ 35 MHz
input_ready=1.990 ms
```

PS polling에서는 RV32I가 `0x120` 직후 `1`을 빠르게 써서 중간 status를
놓칠 수 있다. 이 경우 Vitis app은 최종 완료 시각을 inference done 시각으로
사용한다.
