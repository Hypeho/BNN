# Wide-BDOT128 Ultra96-V1 Vitis loader

이 폴더에는 Vitis 프로젝트에 import할 PS loader 코드만 있다. Platform과
application project 생성, 보드 programming은 수동으로 수행한다.

## LFC Vitis application에 넣을 파일

- `wide_bdot_loader.c`
- `wide_bdot_images.h`

`generate_wide_bdot_vitis_images.py`는 RV32I/Activation/Weight 이미지를 다시
빌드했을 때 헤더를 갱신하는 개발용 도구다. Vitis application build에는 넣지
않는다.

## CNV Vitis application에 넣을 파일

- `cnv_bdot_loader.c`
- `cnv_bdot_images.h`

CNV application에서는 자동 생성된 `helloworld.c`를 Build에서 제외하고
`cnv_bdot_loader.c`를 source로 등록한다. Sources가 `helloworld.c` 이름을 요구하면
`cnv_bdot_loader.c`의 내용을 `helloworld.c`로 사용한다. 기존 Wide-BDOT128 XSA와
bitstream을 그대로 사용하며, CNV 전용 bitstream은 만들 필요가 없다.

CNV loader는 Activation 두 bank를 0으로 초기화한 뒤 IMEM 687 words, DMEM 2,230
words, Weight 51,616 words(206,464 bytes)를 적재한다. 완료 후 prediction, 10개
score와 10개 layer checksum을 모두 검사한다. RTL 예상 실행시간이 약 839 ms이므로
timeout은 3초로 설정되어 있다.

## eBNN Vitis application에 넣을 파일

- `ebnn_bdot_loader.c`
- `ebnn_bdot_images.h`

eBNN도 기존 Wide-BDOT128 XSA와 bitstream을 그대로 사용한다. Loader는 IMEM
1,481 words, DMEM 690 words, Weight 160 words(640 bytes)를 적재하고 Activation
두 bank를 0으로 초기화한다. 완료 후 prediction 5, activation checksum,
BDOT count와 10개 float score bit pattern을 검사한다.

## 수동 프로젝트 생성

1. `vivado_workspace/260817_Wide_BDOT128/export/Wide_BDOT128_Ultra96V1.xsa`로
   platform을 생성한다.
2. `psu_cortexa53_0`의 standalone domain을 선택한다.
3. Empty Application을 생성한다.
4. 실행할 모델에 맞는 loader와 image header 한 쌍을 application에 import한다.
5. Vitis component의 Sources 목록에 선택한 loader가 등록된 것을 확인한 뒤 자동
   생성된 `helloworld.c`를 Build에서 제외한다. Sources 목록이 계속 `helloworld.c`
   를 요구하면 선택한 loader 내용을 `helloworld.c`라는 이름으로 교체한다.
6. application을 Clean/Build하고 Hardware에서 실행한다.

이 loader는 `xil_io`, `xil_cache`, `xil_printf`, `xiltimer`, `sleep` BSP API를
사용하므로 standalone BSP를 기준으로 한다. 이미지 배열은 약 370 KiB이므로 PS
application의 linker memory는 반드시 DDR을 사용해야 한다.

## 동작 순서

1. AXI GPIO channel 1을 output, channel 2를 input으로 설정한다.
2. GPIO=`3`으로 `load_mode=1`, `async_reset=1`을 유지한다.
3. IMEM/DMEM/Activation 0/1을 초기화하고 모든 image를 적재한다.
4. 기본 설정에서는 전체 image를 AXI read-back해 검증한다.
5. GPIO=`1`로 reset을 해제하고 1 us 기다린다.
6. GPIO=`0`으로 Port A 소유권을 RV32I로 넘겨 실행한다.
7. DMEM mailbox 완료를 기다리고 prediction과 score를 검사한다.
8. GPIO=`3`으로 RV32I를 정지하고 loader ownership을 복구한다.

전체 read-back 시간을 줄이려면 application compiler symbol에
`WIDE_BDOT_FULL_READBACK=0`을 정의한다. 최초 보드 검증에서는 기본값 1을
권장한다.

## 하드웨어 주소

| 용도 | PS 주소 | 물리 용량 |
|---|---:|---:|
| Instruction BRAM | `0xA0000000` | 128 KiB |
| Data BRAM | `0xA2000000` | 64 KiB |
| Control/status GPIO | `0xA3000000` | 4 KiB |
| Activation 0 | `0xA4000000` | 32 KiB |
| Activation 1 | `0xA4010000` | 32 KiB |
| Weight | `0xA5000000` | 400 KiB |

Weight의 AXI decode window는 512 KiB지만 실제 BRAM은 400 KiB다. Loader는 사용
중인 378,112 byte만 기록하며 `0xA5064000` 이상에는 접근하지 않는다.

## 예상 UART 결과

시간 값은 PS timer 및 AXI 상태에 따라 달라질 수 있다.

```text
Wide-BDOT128 Ultra96-V1 PS loader
...
READBACK PASS IMEM ...
READBACK PASS DMEM ...
READBACK PASS ACT0 input ...
READBACK PASS ACT0 padding ...
READBACK PASS ACT1 ...
READBACK PASS WEIGHT ...
status=1 prediction=5 expected=5 correct=1
scores=[-182,-94,-34,326,-162,556,54,6,216,-96]
Wide-BDOT128 FINN LFC PASS
```

CNV application의 예상 결과는 다음과 같다.

```text
Wide-BDOT128 FINN CNV Ultra96-V1 PS loader
...
status=1 prediction=3 expected=3 correct=1 layer_checks=1
scores=[-40,-46,-32,404,-30,24,-14,-28,-16,-42]
checksums=[c112c55a,d132e492,9ad5c9fa,c038297d,5d36067d,338d91b0,8d98f679,2e9f3c9d,aa108d24,9a737f7e]
Wide-BDOT128 FINN CNV PASS
```

eBNN application의 예상 결과는 다음과 같다.

```text
Wide-BDOT128 eBNN Binary-MNIST Ultra96-V1 PS loader
...
status=1 prediction=5 expected=5 correct=1 checksum=82552330 bdot=3250
score_bits=[be9a0152,bf3c8938,bee0d7fe,4015220b,bfb6ae47,40815608,bd9bda49,3fb3df63,be806104,bfaebdc9]
Wide-BDOT128 eBNN Binary-MNIST PASS
```

## 이미지 갱신

RV32I 프로그램 또는 parameter image를 변경한 경우 프로젝트 루트에서 다음을
실행한다.

```bash
RV32I-Project/FPGA/BNN/260817_Wide_BDOT128/software/lfc/build_lfc_bdot.sh
python3 RV32I-Project/FPGA/BNN/260817_Wide_BDOT128/Vitis/generate_wide_bdot_vitis_images.py
```

Generator는 IMEM/DMEM 용량, Activation zero padding, Weight 400 KiB 및 사용
범위를 검사한 뒤 `wide_bdot_images.h`를 다시 만든다.

CNV 이미지를 갱신하려면 다음을 실행한다.

```bash
RV32I-Project/FPGA/BNN/260817_Wide_BDOT128/software/cnv/build_cnv_bdot.sh
python3 RV32I-Project/FPGA/BNN/260817_Wide_BDOT128/Vitis/generate_cnv_bdot_vitis_images.py
```

eBNN 이미지를 갱신하려면 다음을 실행한다.

```bash
RV32I-Project/FPGA/BNN/260817_Wide_BDOT128/software/ebnn/build_ebnn_bdot.sh
python3 RV32I-Project/FPGA/BNN/260817_Wide_BDOT128/Vitis/generate_ebnn_bdot_vitis_images.py
```
