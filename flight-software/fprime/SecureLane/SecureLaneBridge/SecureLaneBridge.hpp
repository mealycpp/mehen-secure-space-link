// ======================================================================
// \title  SecureLaneBridge.hpp
// \author xilinx
// \brief  hpp file for SecureLaneBridge component implementation class
// ======================================================================

#ifndef SecureLane_SecureLaneBridge_HPP
#define SecureLane_SecureLaneBridge_HPP

#include "SecureLaneBridge/SecureLaneBridgeComponentAc.hpp"
#include <string>

namespace SecureLane {

class SecureLaneBridge final : public SecureLaneBridgeComponentBase {
  public:
    //! Construct SecureLaneBridge object
    SecureLaneBridge(const char* const compName);

    //! Destroy SecureLaneBridge object
    ~SecureLaneBridge();

  private:
    U32 m_cliOkCount = 0;
    U32 m_cliErrCount = 0;

    static std::string trimNewlines(std::string s);
    static bool isHexString(const std::string& s);
    static std::string runCmd(const std::string& cmd, int& rc);

  protected:
    void GET_KEY128_cmdHandler(
        FwOpcodeType opCode,
        U32 cmdSeq
    ) override;

    void HASH_TEST_cmdHandler(
        FwOpcodeType opCode,
        U32 cmdSeq
    ) override;

    void XOF_TEST_cmdHandler(
        FwOpcodeType opCode,
        U32 cmdSeq
    ) override;

    void ROUNDTRIP_cmdHandler(
        FwOpcodeType opCode,
        U32 cmdSeq
    ) override;
};

}  // namespace SecureLane

#endif
