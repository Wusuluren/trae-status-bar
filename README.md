# trae-status-bar [powered by ai] 

## 编译运行
pkill -9 -f "trae-status-bar" 2>/dev/null; sleep 0.3; rm trae-status-bar 2>/dev/null && swiftc -o trae-status-bar Sources/trae-status-bar/main.swift -framework AppKit 2>&1 && echo "=== BUILD OK ==="

## 查看状态
launchctl list com.trae.statusbar

## 停止
launchctl unload ~/Library/LaunchAgents/com.trae.statusbar.plist

## 查看日志
cat /tmp/trae-status-bar.stdout

## 重新加载（更新二进制后）
launchctl unload ~/Library/LaunchAgents/com.trae.statusbar.plist
launchctl load ~/Library/LaunchAgents/com.trae.statusbar.plist
