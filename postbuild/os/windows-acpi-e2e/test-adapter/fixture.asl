// SPDX-License-Identifier: MIT

DefinitionBlock ("", "SSDT", 2, "ODP", "E2ETEST", 1)
{
    Scope (\_SB)
    {
        Device (ECT0)
        {
            Name (_HID, "ETST0001")
            Name (_UID, Zero)
            Name (_CCA, Zero)

            Method (_STA, 0, NotSerialized)
            {
                Return (0x0F)
            }

            Method (TEST, 0, NotSerialized)
            {
                Return (0x12345678)
            }
        }
    }
}
