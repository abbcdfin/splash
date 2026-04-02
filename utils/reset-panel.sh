#!/bin/bash

systemctl stop drm-splash
echo "5450000.dsi" > /sys/bus/platform/drivers/sun6i-mipi-dsi/unbind
echo "5451000.phy" > /sys/bus/platform/drivers/sun6i-mipi-dphy/unbind

echo 129 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio129/direction
echo 0 > /sys/class/gpio/gpio129/value
sleep 3
echo 129 > /sys/class/gpio/unexport

echo "5451000.phy" > /sys/bus/platform/drivers/sun6i-mipi-dphy/bind
