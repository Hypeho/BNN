#include <stdint.h>

#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiltimer.h"

#include "cnv_bdot_images.h"

#define IMEM_BASE            0xA0000000U
#define DMEM_BASE            0xA2000000U
#define CONTROL_GPIO_BASE    0xA3000000U
#define ACTIVATION0_BASE     0xA4000000U
#define ACTIVATION1_BASE     0xA4010000U
#define WEIGHT_BASE          0xA5000000U

#define IMEM_BYTES           0x00020000U
#define DMEM_BYTES           0x00010000U
#define ACTIVATION_BYTES     0x00008000U
#define WEIGHT_BYTES         0x00064000U
#define WORD_BYTES           4U

#define GPIO_DATA_OFFSET     0x0U
#define GPIO_TRI_OFFSET      0x4U
#define GPIO2_DATA_OFFSET    0x8U
#define GPIO2_TRI_OFFSET     0xCU
#define GPIO_LOAD_MODE       0x1U
#define GPIO_ASYNC_RESET     0x2U
#define GPIO_BDOT_BUSY       0x1U
#define GPIO_BDOT_ERROR      0x2U

#define RESULT_STATUS_WORD       0U
#define RESULT_PREDICTION_WORD   1U
#define RESULT_EXPECTED_WORD     2U
#define RESULT_CORRECT_WORD      3U
#define RESULT_LAYER_CHECK_WORD  4U
#define RESULT_SCORE_BASE_WORD   16U
#define RESULT_CHECKSUM_BASE_WORD 32U
#define RESULT_VALUE_COUNT       10U

#define RV32I_CLOCK_HZ       35000000ULL
#define RUN_TIMEOUT_US       3000000U

#ifndef CNV_BDOT_FULL_READBACK
#define CNV_BDOT_FULL_READBACK 1
#endif

static const int32_t expected_scores[RESULT_VALUE_COUNT] = {
    -40, -46, -32, 404, -30, 24, -14, -28, -16, -42
};

static const uint32_t expected_checksums[RESULT_VALUE_COUNT] = {
    0xC112C55AU, 0xD132E492U, 0x9AD5C9FAU, 0xC038297DU,
    0x5D36067DU, 0x338D91B0U, 0x8D98F679U, 0x2E9F3C9DU,
    0xAA108D24U, 0x9A737F7EU
};

static void gpio_set_control(uint32_t value)
{
    Xil_Out32(CONTROL_GPIO_BASE + GPIO_DATA_OFFSET, value & 0x3U);
}

static uint32_t gpio_get_status(void)
{
    return Xil_In32(CONTROL_GPIO_BASE + GPIO2_DATA_OFFSET) & 0x3U;
}

static void write_words(uint32_t base, uint32_t origin_word,
                        const uint32_t *image, uint32_t words)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        Xil_Out32((UINTPTR)base + (UINTPTR)(origin_word + index) * WORD_BYTES,
                  image[index]);
    }
}

static void clear_words(uint32_t base, uint32_t words)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        Xil_Out32((UINTPTR)base + (UINTPTR)index * WORD_BYTES, 0U);
    }
}

static int verify_words(uint32_t base, uint32_t origin_word,
                        const uint32_t *expected, uint32_t words,
                        const char *name)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        const UINTPTR address = (UINTPTR)base +
            (UINTPTR)(origin_word + index) * WORD_BYTES;
        const uint32_t actual = Xil_In32(address);
        if (actual != expected[index]) {
            xil_printf("READBACK FAIL %s word=%lu expected=0x%08lx actual=0x%08lx\r\n",
                       name, (unsigned long)(origin_word + index),
                       (unsigned long)expected[index], (unsigned long)actual);
            return 1;
        }
    }
    xil_printf("READBACK PASS %s words=%lu\r\n", name, (unsigned long)words);
    return 0;
}

static int verify_zero_words(uint32_t base, uint32_t words, const char *name)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        const uint32_t actual = Xil_In32((UINTPTR)base +
                                        (UINTPTR)index * WORD_BYTES);
        if (actual != 0U) {
            xil_printf("READBACK FAIL %s word=%lu expected=0 actual=0x%08lx\r\n",
                       name, (unsigned long)index, (unsigned long)actual);
            return 1;
        }
    }
    xil_printf("READBACK PASS %s zero words=%lu\r\n",
               name, (unsigned long)words);
    return 0;
}

static uint32_t ticks_to_us(XTime ticks)
{
    const uint64_t value = ((uint64_t)ticks * 1000000ULL +
                            COUNTS_PER_SECOND / 2ULL) / COUNTS_PER_SECOND;
    return (uint32_t)value;
}

static uint32_t us_to_rv32i_cycles(uint32_t us)
{
    const uint64_t value = ((uint64_t)us * RV32I_CLOCK_HZ + 500000ULL) /
                           1000000ULL;
    return (uint32_t)value;
}

static int check_image_sizes(void)
{
    if (((CNV_BDOT_IMEM_IMAGE_ORIGIN_WORD + CNV_BDOT_IMEM_IMAGE_WORDS) *
         WORD_BYTES > IMEM_BYTES) ||
        ((CNV_BDOT_DMEM_IMAGE_ORIGIN_WORD + CNV_BDOT_DMEM_IMAGE_WORDS) *
         WORD_BYTES > DMEM_BYTES) ||
        (CNV_BDOT_WEIGHT_IMAGE_WORDS * WORD_BYTES > WEIGHT_BYTES)) {
        xil_printf("LOAD FAIL: a CNV image exceeds its physical BRAM capacity\r\n");
        return 1;
    }
    return 0;
}

static int load_and_verify_images(void)
{
    int failures = 0;

    xil_printf("Clearing IMEM, DMEM and activation banks...\r\n");
    clear_words(IMEM_BASE, IMEM_BYTES / WORD_BYTES);
    clear_words(DMEM_BASE, DMEM_BYTES / WORD_BYTES);
    clear_words(ACTIVATION0_BASE, ACTIVATION_BYTES / WORD_BYTES);
    clear_words(ACTIVATION1_BASE, ACTIVATION_BYTES / WORD_BYTES);

    xil_printf("Loading IMEM=%lu, DMEM=%lu, WEIGHT=%lu words...\r\n",
               (unsigned long)CNV_BDOT_IMEM_IMAGE_WORDS,
               (unsigned long)CNV_BDOT_DMEM_IMAGE_WORDS,
               (unsigned long)CNV_BDOT_WEIGHT_IMAGE_WORDS);
    write_words(IMEM_BASE, CNV_BDOT_IMEM_IMAGE_ORIGIN_WORD,
                cnv_bdot_imem_image, CNV_BDOT_IMEM_IMAGE_WORDS);
    write_words(DMEM_BASE, CNV_BDOT_DMEM_IMAGE_ORIGIN_WORD,
                cnv_bdot_dmem_image, CNV_BDOT_DMEM_IMAGE_WORDS);
    write_words(WEIGHT_BASE, 0U, cnv_bdot_weight_image,
                CNV_BDOT_WEIGHT_IMAGE_WORDS);

#if CNV_BDOT_FULL_READBACK
    xil_printf("Performing complete AXI read-back...\r\n");
    failures += verify_words(IMEM_BASE, CNV_BDOT_IMEM_IMAGE_ORIGIN_WORD,
                             cnv_bdot_imem_image,
                             CNV_BDOT_IMEM_IMAGE_WORDS, "IMEM");
    failures += verify_words(DMEM_BASE, CNV_BDOT_DMEM_IMAGE_ORIGIN_WORD,
                             cnv_bdot_dmem_image,
                             CNV_BDOT_DMEM_IMAGE_WORDS, "DMEM");
    failures += verify_zero_words(ACTIVATION0_BASE,
                                  ACTIVATION_BYTES / WORD_BYTES, "ACT0");
    failures += verify_zero_words(ACTIVATION1_BASE,
                                  ACTIVATION_BYTES / WORD_BYTES, "ACT1");
    failures += verify_words(WEIGHT_BASE, 0U, cnv_bdot_weight_image,
                             CNV_BDOT_WEIGHT_IMAGE_WORDS, "WEIGHT");
#else
    failures += verify_words(IMEM_BASE, CNV_BDOT_IMEM_IMAGE_ORIGIN_WORD,
                             cnv_bdot_imem_image, 1U, "IMEM sample");
    failures += verify_words(DMEM_BASE, CNV_BDOT_DMEM_IMAGE_ORIGIN_WORD,
                             cnv_bdot_dmem_image, 1U, "DMEM sample");
    failures += verify_words(WEIGHT_BASE, 0U,
                             cnv_bdot_weight_image, 1U, "WEIGHT sample");
#endif
    return failures;
}

static int32_t read_result(uint32_t word)
{
    return (int32_t)Xil_In32((UINTPTR)DMEM_BASE +
                             (UINTPTR)word * WORD_BYTES);
}

static int wait_for_completion(XTime start, XTime *finish)
{
    for (;;) {
        const int32_t status = read_result(RESULT_STATUS_WORD);
        const uint32_t gpio_status = gpio_get_status();
        XTime now;
        XTime_GetTime(&now);

        if ((gpio_status & GPIO_BDOT_ERROR) != 0U) {
            *finish = now;
            xil_printf("RUN FAIL: bdot_error asserted, GPIO2=0x%lx\r\n",
                       (unsigned long)gpio_status);
            return -1;
        }
        if (status == 1 || status < 0) {
            *finish = now;
            return status;
        }
        if (ticks_to_us(now - start) >= RUN_TIMEOUT_US) {
            *finish = now;
            xil_printf("RUN TIMEOUT: status=%ld GPIO2=0x%lx\r\n",
                       (long)status, (unsigned long)gpio_status);
            return status;
        }
    }
}

static int check_results(void)
{
    const int32_t status = read_result(RESULT_STATUS_WORD);
    const int32_t prediction = read_result(RESULT_PREDICTION_WORD);
    const int32_t expected = read_result(RESULT_EXPECTED_WORD);
    const int32_t correct = read_result(RESULT_CORRECT_WORD);
    const int32_t layer_checks_ok = read_result(RESULT_LAYER_CHECK_WORD);
    uint32_t index;
    int failures = 0;

    xil_printf("status=%ld prediction=%ld expected=%ld correct=%ld layer_checks=%ld\r\n",
               (long)status, (long)prediction, (long)expected, (long)correct,
               (long)layer_checks_ok);
    if (status != 1 || prediction != 3 || expected != 3 ||
        correct != 1 || layer_checks_ok != 1) {
        ++failures;
    }

    xil_printf("scores=[");
    for (index = 0U; index < RESULT_VALUE_COUNT; ++index) {
        const int32_t actual = read_result(RESULT_SCORE_BASE_WORD + index);
        xil_printf("%ld%s", (long)actual,
                   index + 1U == RESULT_VALUE_COUNT ? "" : ",");
        if (actual != expected_scores[index]) {
            ++failures;
        }
    }
    xil_printf("]\r\nchecksums=[");
    for (index = 0U; index < RESULT_VALUE_COUNT; ++index) {
        const uint32_t actual = (uint32_t)read_result(
            RESULT_CHECKSUM_BASE_WORD + index);
        xil_printf("%08lx%s", (unsigned long)actual,
                   index + 1U == RESULT_VALUE_COUNT ? "" : ",");
        if (actual != expected_checksums[index]) {
            ++failures;
        }
    }
    xil_printf("]\r\n");
    return failures;
}

int main(void)
{
    XTime start;
    XTime finish;
    uint32_t elapsed_us;
    int run_status;
    int failures;

    Xil_DCacheDisable();
    xil_printf("\r\nWide-BDOT128 FINN CNV Ultra96-V1 PS loader\r\n");
    xil_printf("IMEM=0x%08lx DMEM=0x%08lx GPIO=0x%08lx\r\n",
               (unsigned long)IMEM_BASE, (unsigned long)DMEM_BASE,
               (unsigned long)CONTROL_GPIO_BASE);
    xil_printf("ACT0=0x%08lx ACT1=0x%08lx WEIGHT=0x%08lx\r\n",
               (unsigned long)ACTIVATION0_BASE,
               (unsigned long)ACTIVATION1_BASE,
               (unsigned long)WEIGHT_BASE);

    if (check_image_sizes() != 0) {
        return 1;
    }

    Xil_Out32(CONTROL_GPIO_BASE + GPIO_TRI_OFFSET, 0U);
    Xil_Out32(CONTROL_GPIO_BASE + GPIO2_TRI_OFFSET, 0xFFFFFFFFU);
    gpio_set_control(GPIO_LOAD_MODE | GPIO_ASYNC_RESET);

    failures = load_and_verify_images();
    if (failures != 0) {
        xil_printf("LOAD FAIL: %d read-back region(s) failed\r\n", failures);
        return 1;
    }

    gpio_set_control(GPIO_LOAD_MODE);
    usleep(1U);
    XTime_GetTime(&start);
    gpio_set_control(0U);

    run_status = wait_for_completion(start, &finish);
    gpio_set_control(GPIO_LOAD_MODE | GPIO_ASYNC_RESET);

    elapsed_us = ticks_to_us(finish - start);
    xil_printf("run=%lu us, approximately %lu RV32I cycles @ 35 MHz\r\n",
               (unsigned long)elapsed_us,
               (unsigned long)us_to_rv32i_cycles(elapsed_us));
    if (run_status != 1) {
        xil_printf("Wide-BDOT128 FINN CNV RUN FAIL: status=%d\r\n", run_status);
        return 1;
    }

    failures = check_results();
    if (failures == 0) {
        xil_printf("Wide-BDOT128 FINN CNV PASS\r\n");
        return 0;
    }

    xil_printf("Wide-BDOT128 FINN CNV FAIL: %d mismatch(es)\r\n", failures);
    return 1;
}
