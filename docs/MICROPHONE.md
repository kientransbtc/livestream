# Mic rời (mic không dây, tai nghe có mic)

Khi cắm mic rời vào điện thoại, phòng họp tự thu tiếng từ mic đó thay cho mic
của máy, kể cả khi cắm giữa cuộc họp. Rút mic ra thì tự quay về mic của máy.

Thứ tự ưu tiên (`MicrophoneRouter`): USB (đầu thu USB-C/Lightning của mic không
dây) > mic dây/tai nghe có mic > Bluetooth > mic của máy. Có thể chọn tay ở
**Thêm → Micro** (chỉ hiện khi có từ 2 mic); lựa chọn tay giữ nguyên đến khi rút
mic đó ra.

## Vì sao cần

LiveKit 2.13 bỏ qua `selectAudioInput` trên mobile, nên app luôn thu từ mic máy:
người nói đeo mic không dây đi xa điện thoại thì không ai nghe. Bản
`local_packages/flutter_webrtc` bổ sung:

- iOS: `selectAudioInput` đặt `preferredInput` cho AVAudioSession cả khi LiveKit
  quản lý session (LiveKit giữ category/kích hoạt, ta chỉ chọn cổng thu).
- Android: liệt kê mic USB (`TYPE_USB_DEVICE`/`TYPE_USB_HEADSET`) và Bluetooth LE,
  và báo `onDeviceChange` khi cắm/rút mic (audioswitch không theo dõi USB).

## Kiểm tra

Log khi đổi mic: `[Hisale Coaching Hub] Microphone input: <tên> (<loại>)`, ví dụ
`(USBAudio)` trên iOS hoặc `(usb)` trên Android. Thử: vào phòng, bật mic, cắm mic
rời, đi xa điện thoại vài mét và nói; rút mic ra rồi nói tiếp bằng mic máy.
Tiếng hệ thống khi chia sẻ màn hình vẫn được trộn vào mic đang dùng.
