# H3 Studio — เทมเพลต RunPod ของเราเอง (ล็อกเวอร์ชัน)

pod สำหรับ MiniMax H3 บน ComfyUI (CUDA 13.0) ที่ **ไม่อัปเดตเอง**
ทุกอย่าง (ComfyUI, ปลั๊กอิน, โมเดล) ถูกล็อกไว้ใน `lock.env` และเก็บถาวรใน Network Volume

## ส่วนประกอบใน RunPod

| อย่าง | ชื่อ | หมายเหตุ |
|---|---|---|
| เทมเพลต | H3 Studio (ล็อกเวอร์ชัน) CUDA 13.0 | ส่วนตัว (id `jtr5ey5lih`) |
| Network Volume | h3-studio — 100 GB | ศูนย์ EUR-IS-1 (ไอซ์แลนด์) ~$7/เดือน |

## วิธีเปิดใช้งาน (ทุกครั้ง)

1. RunPod → **Pods → Deploy**
2. ด้านบนเลือก **Network Volume: h3-studio** (ระบบจะล็อกศูนย์เป็น EUR-IS-1 เอง)
3. เลือกการ์ด **RTX 5090** (ถ้าเต็ม ใช้ RTX PRO 6000 ได้ แพงกว่าแต่ใช้งานได้เหมือนกัน)
4. **Change Template** → เลือก **H3 Studio (ล็อกเวอร์ชัน) CUDA 13.0**
5. Additional Filters → CUDA Version เลือก **13.0**
6. กด Deploy → รอ ~2–4 นาที → Connect → **พอร์ต 8188** = ComfyUI (ใช้ลิงก์นี้กับแอปยิงคิว RunPod ได้เลย)

พอร์ต 8888 = Jupyter (ดูไฟล์ / log) — รหัสอยู่ในไฟล์ `.jupyter_password` บนเครื่องนี้

## ข้อควรรู้

- **ปิด pod แล้วกด Terminate ได้เลย** — ของทั้งหมดอยู่ใน Volume ไม่หาย
- คลิปที่เจนแล้วอยู่ใน Volume ที่ `/workspace/h3/ComfyUI/output` — ดาวน์โหลดแล้วลบทิ้งเป็นระยะ อย่าให้ Volume เต็ม
- log การเปิดเครื่อง: `/workspace/h3/logs/boot.log` · log ComfyUI: `/workspace/h3/logs/comfyui.log`
- ถ้าบรรทัดใน boot.log ขึ้น `FATAL` = มีปัญหา ให้ส่ง log ให้ Claude ดู

## อยากอัปเดต (เฉพาะเมื่อตั้งใจ)

แก้ `lock.env` (commit ของ ComfyUI/ปลั๊กอิน หรือโมเดล) → เพิ่ม `LOCK_VERSION` → push →
เปลี่ยน `H3_RAW` ในเทมเพลตให้ชี้ commit ใหม่ ครั้งถัดไปที่เปิด pod จะติดตั้งใหม่ให้เอง
(โมเดลที่มีอยู่แล้วไม่โหลดซ้ำ) ถ้าเวอร์ชันใหม่มีปัญหา แค่ชี้ `H3_RAW` กลับ commit เดิม
