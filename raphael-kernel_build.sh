#!/bin/bash
set -e

# ========== 1. 下载内核源码 ==========
git clone https://github.com/GengWei1997/linux.git --branch raphael-$1 --depth 1 linux
patch linux/scripts/package/builddeb < builddeb.patch
cd linux
git add .
git commit -m "builddeb: Add Xiaomi Raphael DTBs to boot partition"

# ========== 2. 获取并合并配置 ==========
wget -O arch/arm64/configs/raphael.config https://raw.githubusercontent.com/GengWei1997/kernel-deb/refs/heads/main/uefi-raphael.config

# ========== 3. 编译内核（带 EFI Stub） ==========
make -j$(nproc) ARCH=arm64 LLVM=-22 defconfig raphael.config

# 关键：确保 EFI 相关配置开启
echo "CONFIG_EFI_STUB=y" >> .config
echo "CONFIG_EFI_GENERIC_STUB=y" >> .config
# 尝试开启 ZBOOT（7.0 内核支持），如果编译失败可以注释掉
echo "CONFIG_EFI_ZBOOT=y" >> .config

make -j$(nproc) ARCH=arm64 LLVM=-22 olddefconfig
make -j$(nproc) ARCH=arm64 LLVM=-22 deb-pkg

# ========== 4. 生成 vmlinuz.efi 并嵌入 DTB ==========
echo "=== 生成 vmlinuz.efi ==="

# 方法 A：如果 CONFIG_EFI_ZBOOT 生效，直接复制
if [ -f "arch/arm64/boot/vmlinuz.efi" ]; then
    echo "找到内核生成的 vmlinuz.efi"
    cp arch/arm64/boot/vmlinuz.efi /tmp/vmlinuz-raw.efi
# 方法 B：如果只有 Image.gz，用 objcopy 生成 PE32+
elif [ -f "arch/arm64/boot/Image.gz" ]; then
    echo "用 objcopy 从 Image.gz 生成 vmlinuz.efi"
    # 创建 EFI 头部（简化，实际应该用内核编译系统的完整 stub）
    # 这里直接用 objcopy 转换，但缺少 EFI stub 头，可能不完整
    # 更好的做法是让内核 Makefile 生成 vmlinuz.efi
    make -j$(nproc) ARCH=arm64 LLVM=-22 vmlinuz.efi || true
fi

# 检查 DTB
DTB="arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb"
if [ ! -f "$DTB" ]; then
    echo "错误：找不到 DTB 文件: $DTB"
    exit 1
fi

# 嵌入 DTB 到 vmlinuz.efi
if [ -f "/tmp/vmlinuz-raw.efi" ]; then
    echo "嵌入 DTB 到 vmlinuz.efi..."
    aarch64-linux-gnu-objcopy \
        --add-section .dtb="$DTB" \
        --set-section-flags .dtb=alloc,readonly,data \
        /tmp/vmlinuz-raw.efi \
        ../vmlinuz.efi
    
    # 验证
    if aarch64-linux-gnu-readelf -S ../vmlinuz.efi 2>/dev/null | grep -q ".dtb"; then
        echo "✓ DTB 成功嵌入 .dtb section"
    else
        echo "✗ DTB 嵌入失败，尝试直接拼接"
        cat arch/arm64/boot/Image.gz "$DTB" > ../vmlinuz.efi
        echo "警告：使用 Image.gz+DTB 拼接，可能不是标准 PE32+"
    fi
else
    echo "警告：未找到 vmlinuz.efi，使用 Image.gz+DTB 拼接"
    cat arch/arm64/boot/Image.gz "$DTB" > ../vmlinuz.efi
fi

cd ..

# ========== 5. 重命名产物 ==========
IMAGE_DEB=$(ls -1 linux-image-*.deb 2>/dev/null | grep -v '\-dbg_' | head -n1)
HEADERS_DEB=$(ls -1 linux-headers-*.deb 2>/dev/null | head -n1)

if [ -n "$IMAGE_DEB" ]; then
    mv "$IMAGE_DEB" linux-image-xiaomi-raphael.deb
fi
if [ -n "$HEADERS_DEB" ]; then
    mv "$HEADERS_DEB" linux-headers-xiaomi-raphael.deb
fi

# ========== 6. 复制其他产物 ==========
cp linux/arch/arm64/boot/Image.gz .
cp linux/arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb .

# ========== 7. 清理 ==========
rm -rf linux

# ========== 8. 打包 firmware 和 alsa ==========
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael

echo "=== 最终产物 ==="
ls -la vmlinuz.efi Image.gz sm8150-xiaomi-raphael.dtb *.deb 2>/dev/null || true
