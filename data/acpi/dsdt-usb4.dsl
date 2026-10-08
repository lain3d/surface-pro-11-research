        Device (UBF0)
        {
            Name (_HID, "QCOM0C6D")  // _HID: Hardware ID
            Alias (\_SB.PSUB, _SUB)
            Name (_CCA, Zero)  // _CCA: Cache Coherency Attribute
            Name (_DEP, Package (0x02)  // _DEP: Dependencies
            {
                \_SB.PEP0, 
                \_SB.UCS0
            })
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }

            Device (PRT0)
            {
                Name (_ADR, Zero)  // _ADR: Address
                Name (_CID, "ACPI0015")  // _CID: Compatible ID
                Name (_S0W, 0x03)  // _S0W: S0 Device Wake State
                Name (_CRS, ResourceTemplate ()  // _CRS: Current Resource Settings
                {
                    Memory32Fixed (ReadWrite,
                        0x1563F000,         // Address Base
                        0x000BFFFF,         // Address Length
                        )
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, ,, )
                    {
                        0x000001F8,
                    }
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, SharedAndWake, ,, )
                    {
                        0x0000011F,
                    }
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, ,, )
                    {
                        0x00000263,
                    }
                })
                Method (PSET, 0, NotSerialized)
                {
                    Return (\_SB.PRS0)
                }

                Method (PHYC, 0, NotSerialized)
                {
                    Name (CFG0, Package (0x00) {})
                    Return (CFG0) /* \_SB_.UBF0.PRT0.PHYC.CFG0 */
                }
            }

            Device (PRT1)
            {
                Name (_ADR, One)  // _ADR: Address
                Name (_CID, "ACPI0015")  // _CID: Compatible ID
                Name (_S0W, 0x03)  // _S0W: S0 Device Wake State
                Name (_CRS, ResourceTemplate ()  // _CRS: Current Resource Settings
                {
                    Memory32Fixed (ReadWrite,
                        0x1573F000,         // Address Base
                        0x000BFFFF,         // Address Length
                        )
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, ,, )
                    {
                        0x0000027D,
                    }
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, SharedAndWake, ,, )
                    {
                        0x0000022B,
                    }
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, ,, )
                    {
                        0x0000027F,
                    }
                })
                Method (PSET, 0, NotSerialized)
                {
                    Return (\_SB.PRS1)
                }

                Method (PHYC, 0, NotSerialized)
                {
                    Name (CFG0, Package (0x00) {})
                    Return (CFG0) /* \_SB_.UBF0.PRT1.PHYC.CFG0 */
                }
            }

            Device (PRT2)
            {
                Name (_ADR, 0x02)  // _ADR: Address
                Name (_CID, "ACPI0015")  // _CID: Compatible ID
                Name (_S0W, 0x03)  // _S0W: S0 Device Wake State
                Name (_CRS, ResourceTemplate ()  // _CRS: Current Resource Settings
                {
                    Memory32Fixed (ReadWrite,
                        0x1553F000,         // Address Base
                        0x000BFFFF,         // Address Length
                        )
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, ,, )
                    {
                        0x000001CD,
                    }
                    Interrupt (ResourceConsumer, Edge, ActiveHigh, SharedAndWake, ,, )
                    {
                        0x00000236,
                    }
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, ,, )
                    {
                        0x000001D6,
                    }
                })
                Method (PSET, 0, NotSerialized)
                {
                    Return (\_SB.PRS2)
                }

                Method (PHYC, 0, NotSerialized)
                {
                    Name (CFG0, Package (0x00) {})
                    Return (CFG0) /* \_SB_.UBF0.PRT2.PHYC.CFG0 */
                }
            }
        }

        Device (UCSI)
        {
            Name (_HID, EisaId ("USBC000"))  // _HID: Hardware ID
            Name (_CID, EisaId ("PNP0CA0"))  // _CID: Compatible ID
            Name (_UID, 0x05)  // _UID: Unique ID
            Name (_DDN, "USB Type-C")  // _DDN: DOS Device Name
            Name (_DEP, Package (0x03)  // _DEP: Dependencies
            {
                \_SB.ABD, 
                \_SB.PMGK, 
                \_SB.UCS0
            })
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((\_SB.PMGK.LKUP > Zero))
                {
                    Return (0x0F)
                }
                Else
                {
                    VERS = 0x0120
                    CCI = Zero
                    MSGI = Zero
                    Return (Zero)
                }
            }

            Device (UCN0)
            {
                Name (_ADR, Zero)  // _ADR: Address
                Method (_UPC, 0, NotSerialized)  // _UPC: USB Port Capabilities
                {
                    Return (\_SB.UUPC.UPCC)
                }

                Method (_PLD, 0, NotSerialized)  // _PLD: Physical Location of Device
                {
                    Return (\_SB.UPLD.PLD0)
                }
            }

            Device (UCN1)
            {
                Name (_ADR, One)  // _ADR: Address
                Method (_UPC, 0, NotSerialized)  // _UPC: USB Port Capabilities
                {
                    Return (\_SB.UUPC.UPCC)
                }

                Method (_PLD, 0, NotSerialized)  // _PLD: Physical Location of Device
                {
                    Return (\_SB.UPLD.PLD1)
                }
            }

            Device (UCN2)
            {
                Name (_ADR, 0x02)  // _ADR: Address
                Method (_UPC, 0, NotSerialized)  // _UPC: USB Port Capabilities
                {
                    Return (\_SB.UUPC.UPCC)
                }

                Method (_PLD, 0, NotSerialized)  // _PLD: Physical Location of Device
                {
                    Return (\_SB.UPLD.PLD2)
                }
            }

            Name (_CRS, ResourceTemplate ()  // _CRS: Current Resource Settings
            {
                Memory32Fixed (ReadWrite,
                    0x81F20000,         // Address Base
                    0x00000030,         // Address Length
                    )
            })
            OperationRegion (USBC, SystemMemory, 0x81F20000, 0x30)
            Field (USBC, ByteAcc, Lock, Preserve)
            {
                VERS,   16, 
                RESV,   16, 
                CCI,    32, 
                CTRL,   64, 
                MSGI,   128, 
                MSGO,   128
            }

            Name (BUFF, Buffer (0x32) {})
            CreateField (BUFF, Zero, 0x08, BSTA)
            CreateField (BUFF, 0x08, 0x08, BSIZ)
            CreateField (BUFF, 0x10, 0x10, BVER)
            CreateField (BUFF, 0x30, 0x20, BCCI)
            CreateField (BUFF, 0x50, 0x40, BCTL)
            CreateField (BUFF, 0x90, 0x80, BMGI)
            CreateField (BUFF, 0x0110, 0x80, BMGO)
            Mutex (BMTX, 0x00)
            Method (OPMW, 0, NotSerialized)
            {
                Acquire (BMTX, 0xFFFF)
                BCTL = CTRL /* \_SB_.UCSI.CTRL */
                BMGO = MSGO /* \_SB_.UCSI.MSGO */
                \_SB.PMGK.UCSI = BUFF /* \_SB_.UCSI.BUFF */
                Release (BMTX)
                Return (Zero)
            }

            Method (OPMR, 0, NotSerialized)
            {
                Acquire (BMTX, 0xFFFF)
                BUFF = \_SB.PMGK.UCSI
                VERS = BVER /* \_SB_.UCSI.BVER */
                CCI = BCCI /* \_SB_.UCSI.BCCI */
                MSGI = BMGI /* \_SB_.UCSI.BMGI */
                Release (BMTX)
                Return (Zero)
            }

            Method (_DSM, 4, Serialized)  // _DSM: Device-Specific Method
            {
                If ((Arg0 == ToUUID ("6f8398c2-7ca4-11e4-ad36-631042b5008f") /* Unknown UUID */))
                {
                    While (One)
                    {
                        Name (_T_0, 0x00)  // _T_x: Emitted by ASL Compiler, x=0-9, A-Z
                        _T_0 = ToInteger (Arg2)
                        If ((_T_0 == Zero))
                        {
                            Return (Buffer (One)
                            {
                                 0x0F                                             // .
                            })
                        }
                        ElseIf ((_T_0 == One))
                        {
                            Return (OPMW ())
                        }
                        ElseIf ((_T_0 == 0x02))
