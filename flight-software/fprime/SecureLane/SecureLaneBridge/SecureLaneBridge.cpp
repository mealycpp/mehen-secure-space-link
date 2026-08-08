// ======================================================================
// \title  SecureLaneBridge.cpp
// \author xilinx
// \brief  cpp file for SecureLaneBridge component implementation class
// ======================================================================

#include "SecureLaneBridge/SecureLaneBridge.hpp"

#include <array>
#include <cctype>
#include <cstdio>
#include <string>
#include <sys/wait.h>

namespace SecureLane {

static const std::string kPy =
    "sudo -E /usr/local/share/pynq-venv/bin/python "
    "/home/xilinx/spaccomputing/ascon_hw_cli.py";

// ----------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------

std::string SecureLaneBridge::trimNewlines(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) {
        s.pop_back();
    }
    return s;
}

bool SecureLaneBridge::isHexString(const std::string& s) {
    if (s.empty()) {
        return false;
    }
    for (char c : s) {
        if (!std::isxdigit(static_cast<unsigned char>(c))) {
            return false;
        }
    }
    return true;
}

std::string SecureLaneBridge::runCmd(const std::string& cmd, int& rc) {
    std::array<char, 256> buf{};
    std::string out;

    FILE* fp = ::popen(cmd.c_str(), "r");
    if (fp == nullptr) {
        rc = -1;
        return "";
    }

    while (fgets(buf.data(), static_cast<int>(buf.size()), fp) != nullptr) {
        out += buf.data();
    }

    int status = ::pclose(fp);
    if (WIFEXITED(status)) {
        rc = WEXITSTATUS(status);
    } else {
        rc = status;
    }

    return trimNewlines(out);
}

// ----------------------------------------------------------------------
// Component construction and destruction
// ----------------------------------------------------------------------

SecureLaneBridge::SecureLaneBridge(const char* const compName) :
    SecureLaneBridgeComponentBase(compName) {
}

SecureLaneBridge::~SecureLaneBridge() {
}

// ----------------------------------------------------------------------
// Command handlers
// ----------------------------------------------------------------------

void SecureLaneBridge::GET_KEY128_cmdHandler(FwOpcodeType opCode, U32 cmdSeq) {
    int rc = 0;
    const std::string out = runCmd(kPy + " trng-key128", rc);

    this->tlmWrite_LastCmdId(0);
    this->tlmWrite_LastCliRc(rc);

    if (rc != 0 || out.size() != 32 || !isHexString(out)) {
        this->tlmWrite_CliErrCount(++this->m_cliErrCount);
        this->log_WARNING_HI_CliError();
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    this->tlmWrite_CliOkCount(++this->m_cliOkCount);
    this->log_ACTIVITY_HI_Key128Ready();
    this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::OK);
}

void SecureLaneBridge::HASH_TEST_cmdHandler(FwOpcodeType opCode, U32 cmdSeq) {
    static const std::string exp =
        "0728621035af3ed2bca03bf6fde900f9456f5330e4b5ee23e7f6a1e70291bc80";

    int rc = 0;
    const std::string out = runCmd(kPy + " hash --msg 00", rc);

    this->tlmWrite_LastCmdId(1);
    this->tlmWrite_LastCliRc(rc);

    if (rc != 0 || out != exp) {
        this->tlmWrite_CliErrCount(++this->m_cliErrCount);
        this->log_WARNING_HI_CliError();
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    this->tlmWrite_CliOkCount(++this->m_cliOkCount);
    this->log_ACTIVITY_HI_HashOk();
    this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::OK);
}

void SecureLaneBridge::XOF_TEST_cmdHandler(FwOpcodeType opCode, U32 cmdSeq) {
    static const std::string exp =
        "51430e0438ecdf642b393630d977625f5f337656ba58ab1e960784ac32a16e0d"
        "446405551f5469384f8ea283cf12e64fa72c426bfebaea3aa1529e2c4ab23a2f";

    int rc = 0;
    const std::string out = runCmd(kPy + " xof --msg 00 --out-len 64", rc);

    this->tlmWrite_LastCmdId(2);
    this->tlmWrite_LastCliRc(rc);

    if (rc != 0 || out != exp) {
        this->tlmWrite_CliErrCount(++this->m_cliErrCount);
        this->log_WARNING_HI_CliError();
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    this->tlmWrite_CliOkCount(++this->m_cliOkCount);
    this->log_ACTIVITY_HI_XofOk();
    this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::OK);
}

void SecureLaneBridge::ROUNDTRIP_cmdHandler(FwOpcodeType opCode, U32 cmdSeq) {
    static const std::string nonce = "00112233445566778899aabbccddeeff";
    static const std::string ad    = "a1a2a3a4";
    static const std::string pt    = "112233445566";

    this->tlmWrite_LastCmdId(3);

    int rc = 0;
    const std::string key = runCmd(kPy + " trng-key128", rc);
    if (rc != 0 || key.size() != 32 || !isHexString(key)) {
        this->tlmWrite_LastCliRc(rc);
        this->tlmWrite_CliErrCount(++this->m_cliErrCount);
        this->log_WARNING_HI_RoundTripFail();
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    const std::string encCmd =
        kPy + " aead-enc --key " + key +
        " --nonce " + nonce +
        " --ad " + ad +
        " --pt " + pt;

    const std::string ct = runCmd(encCmd, rc);
    if (rc != 0 || !isHexString(ct)) {
        this->tlmWrite_LastCliRc(rc);
        this->tlmWrite_CliErrCount(++this->m_cliErrCount);
        this->log_WARNING_HI_RoundTripFail();
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    const std::string decCmd =
        kPy + " aead-dec --key " + key +
        " --nonce " + nonce +
        " --ad " + ad +
        " --ct " + ct;

    const std::string gotPt = runCmd(decCmd, rc);
    this->tlmWrite_LastCliRc(rc);

    if (rc != 0 || gotPt != pt) {
        this->tlmWrite_CliErrCount(++this->m_cliErrCount);
        this->log_WARNING_HI_RoundTripFail();
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    this->tlmWrite_CliOkCount(++this->m_cliOkCount);
    this->log_ACTIVITY_HI_RoundTripOk();
    this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::OK);
}

}  // namespace SecureLane
