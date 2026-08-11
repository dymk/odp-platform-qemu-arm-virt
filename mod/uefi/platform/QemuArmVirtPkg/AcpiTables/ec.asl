/** @file
  Contains root level name space objects for the platform

  Copyright (c) 2024, MediaTek Inc. All rights reserved.<BR>
  SPDX-License-Identifier: BSD-2-Clause-Patent

**/

DefinitionBlock ("SsdtEc.aml", "SSDT", 2, "QEMUAR", "EC      ", 1) {

  Scope(\_SB)
  {
    #include "ffa.asl"
    #include "hid.asl"
    //#include "battery.asl"
    //#include "thermal.asl"
    //#include "rtc.asl"

  //
  // EC Test interface to load KMDF driver and map methods
  //
  Device (ECT0) {
    Name (_HID, "ETST0001")
    Name (_UID, 0x0)
    Name (_CCA, 0x0)

    /*********************** General Methods **********************************/
    Name (NEVT, 0x1234)

    Name(BUFF, Buffer(144){})   // Create buffer for send/recv data
  
    Method(ECHO, 0x1, NotSerialized) {
      Return(Arg0) // Echo back input
    }

    Name(UMBX, Buffer(48){})    // UCSI mailbox carried inline in the FF-A payload

    // USND — route a UCSI command through the FF-A doorbell (FFA0.FFAC).
    // Arg0: 8-byte CONTROL buffer (opcode @0, connector @2). The 144-byte
    // BUFF is the FF-A envelope: status @0, service UUID @bit128, doorbell
    // tag @byte32 (payload byte 0), the 48-byte request mailbox @byte33
    // (payload byte 1), and the 48-byte response mailbox @byte32 (payload
    // byte 0). Returns the response mailbox (VERSION @0, CCI @4, MESSAGE IN @16).
    Method(USND, 1, Serialized) {
      CreateDwordField(BUFF, 0, STAT)     // Out - FF-A status
      CreateField(BUFF, 128, 128, UUID)   // Service UUID
      CreateByteField(BUFF, 32, CMDD)     // In  - doorbell tag
      CreateField(BUFF, 264, 384, WMBX)   // In  - request mailbox (payload byte 1)
      CreateField(BUFF, 256, 384, RMBX)   // Out - response mailbox (payload byte 0)
      CreateField(UMBX, 64, 64, UCTL)     // CONTROL at mailbox offset 8

      Store(Arg0, UCTL)
      Store(0x00, CMDD)
      Store(UMBX, WMBX)
      Store(ToUUID("65467f50-827f-4e4f-8770-dbf4c3f77f45"), UUID)

      Store(Store(BUFF, \_SB_.FFA0.FFAC), BUFF)
      If(LEqual(STAT, 0x0)) {  // FF-A successful?
        Return(RMBX)
      }
      Return(Buffer(48){})
    }

    Method (_STA) {
      Return (0xf)
    }

  } // Device (ECT0)

  }

}
