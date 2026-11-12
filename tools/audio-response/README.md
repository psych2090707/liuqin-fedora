# 固定测试音的内核音色对照

用途：减少反复听同一段声音造成的判断疲劳，检测候选是否出现高频衰减。
这是未校准的声学对照，不是扬声器绝对频响、响度或失真认证。

依据 [PipeWire pw-cat 官方接口](https://docs.pipewire.org/page_man_pw-cat_1.html)，
同时采集数字输出 monitor 和内置麦克风。固定 48 kHz 多音测试信号，
250 Hz–12.5 kHz 共 11 个频点，三个 2 秒片段；每次采集 14 秒。
刺激 PCM 峰值 0.08，保持已有输出音量 20%、输入 100%，不调整 mixer、
固件、保护、服务或持久配置。音量前提来自这次现场基线，不是通用推荐音量。

主机需要 numpy；设备采集仅需 Python 标准库、PipeWire 工具及只读 sudo amixer。
工具不会重启或上传数据；录音只写用户 runtime tmpfs。环境或放置改变时应重新建基线。
先确认附近没有私人谈话、没有其他播放/录音，保持平板位置、支撑及麦克风遮挡不变。

```sh
python3 -B tools/audio-response/measure.py generate /tmp/audio-stimulus
# 将同一 stimulus.wav 和 measure.py 放进设备新的 /run/user/1000/ 测量目录。
# 以下在设备执行，Build ID 必须来自目标构建：
python3 measure.py capture /run/user/1000/audio-A --expect-build-id EXACT_BUILD_ID
# 取回 capture.json、mic.s32、monitor.s32、日志到私有本机目录后：
python3 -B tools/audio-response/measure.py analyse /tmp/private-audio-A
python3 -B -m unittest discover -s tests/audio-response -p 'test_*.py' -v
```

分析用 0.1 秒网格定位三个片段，`lag_s` 只是窗口定位，不能解释为设备延迟。
取各片段中间 1 秒，Hann 窗 FFT 积分每个频点 ±3 Hz 功率，扣除前置背景功率，
汇报三次中位数、极差及背景余量。已用已知增益、人工 38 dB 高频损失、纯噪声和短文件验证。
弱信号、不稳定、削波或采样不完整的数据不能支持结论。

本机 mic 只有 channel 0 有效，monitor 的 channel 0/1 有效，其他为静音；
不能据通道数声称测到了四路独立扬声器。四路 DSP 路由、校准与 HALO_STATE 另在播放中读取。
`pw-record` 到 sample-count 的 EOS 在本机返回 1 且日志空，因此保留原始退出码，
独立核对完整字节数和信号质量，而不只看退出码。

比较 mic/monitor 的传递量，再以 1 kHz 归一化判断音色；数字 monitor 只能排查其采样点之前的链路，
麦克风包含功放、扬声器、机身耦合、房间和录音链路。三片段极差只是片段内重复性，
不能代替跨启动误差或统计置信区间。小差异不能直接归因内核；没有宽带大幅衰减也不能证明音乐完全相同。
如需要判断细小差别，下一阶段应固定外部麦克风/夹具，采用多次 A/B/A；不要直接消耗槽位重试反复重启。
原始录音可能包含环境声音，只留本机私有目录；仓库只存数值摘要。
