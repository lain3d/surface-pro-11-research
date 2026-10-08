            }
        }

        Device (SSGS)
        {
            Name (_HID, "QCOM06D8")  // _HID: Hardware ID
            Alias (\_SB.PSUB, _SUB)
            Name (_UID, Zero)  // _UID: Unique ID
        }

        Device (DCF)
        {
            Name (_DEP, Package (0x03)  // _DEP: Dependencies
            {
                \_SB.IPC0, 
                \_SB.ADSP, 
                \_SB.ARPC
            })
            Name (_HID, "QCOM06E7")  // _HID: Hardware ID
            Alias (\_SB.PSUB, _SUB)
            Name (_CID, "QCOM06E7")  // _CID: Compatible ID
        }

        Device (SOCD)
        {
            Name (_HID, "QCOM0D18")  // _HID: Hardware ID
            Alias (\_SB.PSUB, _SUB)
            Alias (\_SB.SDFE, SDFE)
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((\_SB.SDFE == 0x88))
                {
                    Return (Zero)
                }
                Else
                {
                    Return (0x0F)
                }
            }
        }

        Device (CAMP)
        {
            Name (_DEP, Package (0x03)  // _DEP: Dependencies
            {
                \_SB.PEP0, 
                \_SB.PMIC, 
                \_SB.GIO0
            })
            Name (_HID, "QCOM0C32")  // _HID: Hardware ID
            Name (_UID, 0x1B)  // _UID: Unique ID
            Name (_SUB, "MSHW0495")  // _SUB: Subsystem ID
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }

            Method (_CRS, 0, NotSerialized)  // _CRS: Current Resource Settings
            {
                Name (RBUF, ResourceTemplate ()
                {
                    Memory32Fixed (ReadWrite,
                        0x0AC13000,         // Address Base
                        0x00001000,         // Address Length
                        )
                    Memory32Fixed (ReadWrite,
                        0x0AC19000,         // Address Base
                        0x0000C000,         // Address Length
                        )
                    Memory32Fixed (ReadWrite,
                        0x0AC15000,         // Address Base
                        0x00001000,         // Address Length
                        )
                    Memory32Fixed (ReadWrite,
                        0x0AC16000,         // Address Base
                        0x00001000,         // Address Length
                        )
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                    {
                        0x000001EC,
                    }
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                    {
                        0x0000012F,
                    }
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                    {
                        0x000001EB,
                    }
                    GpioIo (Exclusive, PullNone, 0x0000, 0x0000, IoRestrictionNone,
                        "\\_SB.GIO0", 0x00, ResourceConsumer, ,
                        )
                        {   // Pin list
                            0x00E1
                        }
                    GpioIo (Exclusive, PullNone, 0x0000, 0x0000, IoRestrictionNone,
                        "\\_SB.GIO0", 0x00, ResourceConsumer, ,
                        )
                        {   // Pin list
                            0x0069
                        }
                })
                Return (RBUF) /* \_SB_.CAMP._CRS.RBUF */
            }
        }

        Device (CAMS)
        {
            Name (_DEP, Package (One)  // _DEP: Dependencies
            {
                \_SB.MPCS
            })
            Name (_HID, "OVTID858")  // _HID: Hardware ID
            Name (_UID, 0x15)  // _UID: Unique ID
            Name (_SUB, "MSHW0491")  // _SUB: Subsystem ID
            Method (_HRV, 0, NotSerialized)  // _HRV: Hardware Revision
            {
                If ((\_SB.SDFE == 0x9A))
                {
                    Return (One)
                }
                Else
                {
                    Return (Zero)
                }
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }
        }

        Device (CAMF)
        {
            Name (_DEP, Package (One)  // _DEP: Dependencies
            {
                \_SB.MPCS
            })
            Name (_HID, "SONY0681")  // _HID: Hardware ID
            Name (_UID, 0x1A)  // _UID: Unique ID
            Name (_SUB, "MSHW0490")  // _SUB: Subsystem ID
            Method (_HRV, 0, NotSerialized)  // _HRV: Hardware Revision
            {
                If ((\_SB.SDFE == 0x9A))
                {
                    Return (One)
                }
                Else
                {
                    Return (Zero)
                }
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }
        }

        Device (CAMI)
        {
            Name (_DEP, Package (One)  // _DEP: Dependencies
            {
                \_SB.MPCS
            })
            Name (_HID, "SMO55F0")  // _HID: Hardware ID
            Name (_UID, 0x1C)  // _UID: Unique ID
            Name (_SUB, "MSHW0492")  // _SUB: Subsystem ID
            Method (_HRV, 0, NotSerialized)  // _HRV: Hardware Revision
            {
                If ((\_SB.SDFE == 0x9A))
                {
                    Return (One)
                }
                Else
                {
                    Return (Zero)
                }
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }
        }

        Device (FLSH)
        {
            Name (_DEP, Package (One)  // _DEP: Dependencies
            {
                \_SB.CAMP
            })
            Name (_HID, "QCOM0C27")  // _HID: Hardware ID
            Name (_UID, 0x19)  // _UID: Unique ID
            Alias (\_SB.PSUB, _SUB)
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }

            Method (_CRS, 0, NotSerialized)  // _CRS: Current Resource Settings
            {
                Name (RBUF, Buffer (0x02)
                {
                     0x79, 0x00                                       // y.
                })
                Return (RBUF) /* \_SB_.FLSH._CRS.RBUF */
            }
        }

        Device (MPCS)
        {
            Name (_DEP, Package (One)  // _DEP: Dependencies
            {
                \_SB.CAMP
            })
            Name (_HID, "QCOM0C98")  // _HID: Hardware ID
            Name (_UID, 0x18)  // _UID: Unique ID
            Alias (\_SB.PSUB, _SUB)
            Name (HBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite,
                    0x0ACE4000,         // Address Base
                    0x00002000,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACE6000,         // Address Base
                    0x00002000,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACE8000,         // Address Base
                    0x00002000,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACEC000,         // Address Base
                    0x00002000,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACF6000,         // Address Base
                    0x00000400,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACF7000,         // Address Base
                    0x00000400,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACF8000,         // Address Base
                    0x00000400,         // Address Length
                    )
                Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                {
                    0x000001FD,
                }
                Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                {
                    0x000001FE,
                }
                Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                {
                    0x000001FF,
                }
                Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                {
                    0x0000009A,
                }
            })
            Name (PBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite,
                    0x0ACE4000,         // Address Base
                    0x00002000,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACEC000,         // Address Base
                    0x00002000,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACF6000,         // Address Base
                    0x00000400,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACF7000,         // Address Base
                    0x00000400,         // Address Length
                    )
                Memory32Fixed (ReadWrite,
                    0x0ACF8000,         // Address Base
                    0x00000400,         // Address Length
                    )
                Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                {
                    0x000001FD,
                }
                Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                {
                    0x0000009A,
                }
            })
            Method (_HRV, 0, NotSerialized)  // _HRV: Hardware Revision
            {
                If ((\_SB.SDFE == 0x9A))
                {
                    Return (One)
                }
                Else
                {
                    Return (Zero)
                }
            }

            Method (_CRS, 0, NotSerialized)  // _CRS: Current Resource Settings
            {
                If ((\_SB.SDFE == 0x88))
                {
                    Return (HBUF) /* \_SB_.MPCS.HBUF */
                }
                ElseIf ((\_SB.SDFE == 0x9A))
                {
                    Return (PBUF) /* \_SB_.MPCS.PBUF */
                }
            }
        }

        Device (JPGE)
        {
            Name (_DEP, Package (0x02)  // _DEP: Dependencies
            {
                \_SB.CAMP, 
                \_SB.MMU0
            })
            Name (_HID, "QCOM0C33")  // _HID: Hardware ID
            Name (_UID, 0x17)  // _UID: Unique ID
            Alias (\_SB.PSUB, _SUB)
            Method (_CRS, 0, NotSerialized)  // _CRS: Current Resource Settings
            {
                Name (RBUF, ResourceTemplate ()
                {
                    Memory32Fixed (ReadWrite,
                        0x0AC2A000,         // Address Base
                        0x00001000,         // Address Length
                        )
                    Memory32Fixed (ReadWrite,
                        0x0AC2B000,         // Address Base
                        0x00001000,         // Address Length
                        )
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                    {
                        0x000001FA,
                    }
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, )
                    {
                        0x000001FB,
                    }
                })
                Return (RBUF) /* \_SB_.JPGE._CRS.RBUF */
            }
        }

        Device (VFE0)
        {
            Name (_DEP, Package (0x07)  // _DEP: Dependencies
