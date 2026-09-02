# FINN CNV-W1A1 RV32I

FINN이 pin한 Brevitas CNV-W1A1의 전체 inference를 RV32I C로 변환했다.
첫 layer는 Q1.7 activation과 W1 add/sub, 이후 5 Conv와 3 FC는 packed
W1A1 XNOR-Popcount로 실행한다. activation은 HWC channel-packed 형식으로
직접 생성하여 layer 사이 scalar repacking을 사용하지 않는다.

```bash
bash script/build.sh
python3 analysis/profile_cnv.py \
  --profiler ../260624_eBNN_Binary_MNIST/analysis/rv32i_profile.py \
  --elf build/finn_cnv.elf --imem build/imem.hex --dmem build/dmem.hex
```

생성된 `generated/cnv_params.h`가 있으면 Brevitas와 checkpoint 없이 다시
컴파일할 수 있다. 재생성에는 FINN의 `fetch-repos.sh`에 지정된 Brevitas
commit `84f42259...`와 official `cnv_1w1a-758c8fef.pth`가 필요하다.

Brevitas, host C, RV32I가 모두 class 3을 예측했다. Conv/Pool/FC packed
activation 10개 지점의 checksum도 모두 일치한다.
