module SecureLane {
    @ Bridge component for TRNG and ASCON hardware lane
    passive component SecureLaneBridge {

        @ Get a fresh 128-bit key from TRNG
        sync command GET_KEY128 opcode 0

        @ Run HASH test on known input
        sync command HASH_TEST opcode 1

        @ Run XOF test on known input
        sync command XOF_TEST opcode 2

        @ Run AEAD encrypt+decrypt roundtrip
        sync command ROUNDTRIP opcode 3

        @ Successful backend calls
        telemetry CliOkCount: U32 id 0

        @ Failed backend calls
        telemetry CliErrCount: U32 id 1

        @ Last CLI return code
        telemetry LastCliRc: I32 id 2

        @ Last command ID
        telemetry LastCmdId: U32 id 3

        @ TRNG key retrieval succeeded
        event Key128Ready severity activity high id 0 format "TRNG key ready"

        @ HASH test succeeded
        event HashOk severity activity high id 1 format "HASH test passed"

        @ XOF test succeeded
        event XofOk severity activity high id 2 format "XOF test passed"

        @ AEAD roundtrip succeeded
        event RoundTripOk severity activity high id 3 format "AEAD roundtrip passed"

        @ AEAD roundtrip failed
        event RoundTripFail severity warning high id 4 format "AEAD roundtrip failed"

        @ Backend/CLI call failed
        event CliError severity warning high id 5 format "Backend call failed"

        @ Port for requesting the current time
        time get port timeCaller

        @ Enables command handling
        import Fw.Command

        @ Enables event handling
        import Fw.Event

        @ Enables telemetry channels handling
        import Fw.Channel

        @ Port to return the value of a parameter
        param get port prmGetOut

        @ Port to set the value of a parameter
        param set port prmSetOut
    }
}
