/*
 * P-EDCA (IEEE 802.11bn) adoption-ratio validation scenario for ns-3.48
 *
 * Purpose:
 *   Same single-BSS, uplink-only, EDCA-ratio architecture as
 *   edca-ratio-validation.cc, EXCEPT that the AC_VO population is now
 *   split into two sub-populations that differ only in whether P-EDCA
 *   (this repo's ns-3.48 patch) is enabled on that station's MAC:
 *
 *       AC_VO_LEGACY : ordinary EDCA, PEdcaSupported=false
 *       AC_VO_PEDCA  : PEdcaSupported=true, eligible for DS-CTS/Stage 2
 *                      once its own QSRC/PSRC conditions are met
 *
 *   This lets you hold total AC_VO station count AND total AC_VO
 *   offered load fixed while varying the ADOPTION RATIO of P-EDCA
 *   within that population, e.g. (nVoLegacy / nVoPedca, N_VO fixed
 *   at 16):
 *
 *       0% adoption   (baseline EDCA):  16 / 0
 *       25% adoption:                  12 / 4
 *       50% adoption:                   8 / 8
 *       75% adoption:                   4 / 12
 *       100% adoption:                  0 / 16
 *
 *   AC_BE / AC_BK / AC_VI remain ordinary EDCA throughout (current
 *   patch gates PedcaEligible() to AC_VO only -- see the P-EDCA
 *   attribute block below if you extend this to AC_VI later).
 *
 * Offered load policy:
 *   FIXED PER-AC LOAD (default, recommended for this experiment),
 *   exactly as in edca-ratio-validation.cc: AC_VO's total demand is
 *   perAcLoadMbps regardless of how the population is split between
 *   the two sub-groups, so a station's individual rate is
 *   perAcLoadMbps / (nVoLegacy + nVoPedca) whichever sub-group it is
 *   in. This isolates the effect of P-EDCA ADOPTION RATIO from the
 *   effect of traffic volume, which is the point of this experiment.
 *
 *   A --perStationLoadFixed flag switches to the alternate policy
 *   (fixed load per STATION) exactly as in the EDCA baseline.
 *
 * P-EDCA parameters (QSRC/PSRC thresholds, DS-CTS and Stage-2
 * contention parameters) are configurable from the command line and
 * applied to every AC_VO EDCAF via Config::Set; they are inert on
 * AC_VO_LEGACY stations since PedcaEligible() first checks
 * GetPEdcaSupported(). Defaults mirror the QosTxop attribute defaults
 * in the patch -- verify them against your target draft before
 * publishing results, as noted throughout the patch's own comments.
 *
 * FlowMonitor, MAC retry counting, RNG handling, and CSV structure
 * otherwise follow edca-ratio-validation.cc exactly, with an added
 * PedcaDsCtsCounter (mirrors MacRetryCounter) that counts DS-CTS
 * transmissions per station via the patch's PsrcTrace trace source.
 */

#include "ns3/abort.h"
#include "ns3/command-line.h"
#include "ns3/core-module.h"
#include "ns3/flow-monitor-helper.h"
#include "ns3/internet-stack-helper.h"
#include "ns3/ipv4-address-helper.h"
#include "ns3/ipv4-flow-classifier.h"
#include "ns3/mobility-helper.h"
#include "ns3/on-off-helper.h"
#include "ns3/position-allocator.h"
#include "ns3/ssid.h"
#include "ns3/string.h"
#include "ns3/udp-client-server-helper.h"
#include "ns3/wifi-helper.h"
#include "ns3/wifi-mac-header.h"
#include "ns3/wifi-net-device.h"
#include "ns3/yans-wifi-channel.h"
#include "ns3/yans-wifi-helper.h"

#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <map>
#include <string>

using namespace ns3;

NS_LOG_COMPONENT_DEFINE("EdcaRatioValidation");

/*
 * --------------------------------------------------------------------------
 * Access Category definition
 * --------------------------------------------------------------------------
 *
 * Intended mapping:
 *
 *   0x70 -> UP 3 -> AC_BE
 *   0x28 -> UP 1 -> AC_BK
 *   0xb8 -> UP 5 -> AC_VI
 *   0xc0 -> UP 6 -> AC_VO
 *
 * IMPORTANT:
 * Verify these values against the exact ns-3.48 QoS mapping in your
 * installed source before using them for publication.
 */

struct AcGroup
{
    std::string label;
    uint8_t tos;
    bool pedcaCapable; // true only for the AC_VO_PEDCA sub-group
};

// Order here fixes group index: 0=BE, 1=BK, 2=VI, 3=VO_LEGACY, 4=VO_PEDCA.
// VO_LEGACY and VO_PEDCA share the same TOS (both map to real AC_VO); they
// differ only in the PEdcaSupported MAC attribute set at Install() time.
const std::array<AcGroup, 5> kAcGroups = {{
    {"AC_BE", 0x70, false},
    {"AC_BK", 0x28, false},
    {"AC_VI", 0xb8, false},
    {"AC_VO_LEGACY", 0xc0, false},
    {"AC_VO_PEDCA", 0xc0, true},
}};

/*
 * --------------------------------------------------------------------------
 * Station -> AC mapping (ratio-aware, P-EDCA-adoption-aware)
 * --------------------------------------------------------------------------
 *
 * Stations are laid out contiguously in the order:
 *
 *   [0 .. nBe)                                   -> AC_BE
 *   [nBe .. nBe+nBk)                              -> AC_BK
 *   [nBe+nBk .. nBe+nBk+nVi)                      -> AC_VI
 *   [nBe+nBk+nVi .. +nVoLegacy)                   -> AC_VO_LEGACY
 *   [nBe+nBk+nVi+nVoLegacy .. numStations)        -> AC_VO_PEDCA
 *
 * numStations = nBe + nBk + nVi + nVoLegacy + nVoPedca, computed by caller.
 */

int
GroupForStation(uint32_t staIndex,
                uint32_t nBe,
                uint32_t nBk,
                uint32_t nVi,
                uint32_t nVoLegacy,
                uint32_t nVoPedca)
{
    (void)nVoPedca; // last group absorbs the remainder; kept for clarity/symmetry

    if (staIndex < nBe)
    {
        return 0; // AC_BE
    }

    if (staIndex < nBe + nBk)
    {
        return 1; // AC_BK
    }

    if (staIndex < nBe + nBk + nVi)
    {
        return 2; // AC_VI
    }

    if (staIndex < nBe + nBk + nVi + nVoLegacy)
    {
        return 3; // AC_VO_LEGACY
    }

    return 4; // AC_VO_PEDCA
}

/*
 * --------------------------------------------------------------------------
 * MAC retry counter
 * --------------------------------------------------------------------------
 *
 * Counts:
 *
 *   1. DATA MPDU transmissions observed at PhyTxBegin
 *   2. DATA MPDU transmissions carrying the IEEE 802.11 Retry bit
 *
 * Maintained per STA (by ns-3 NodeId), aggregated by AC group in main().
 */

class MacRetryCounter
{
  public:
    void Connect(NodeContainer staNodes);

    void Trace(std::string context,
               Ptr<const Packet> packet,
               double txPowerW);

    uint64_t GetRetriesForNode(uint32_t nodeId) const;

    uint64_t GetAttemptsForNode(uint32_t nodeId) const;

  private:
    std::map<uint32_t, uint64_t> m_retriesPerNode;
    std::map<uint32_t, uint64_t> m_attemptsPerNode;
};

void
MacRetryCounter::Connect(NodeContainer staNodes)
{
    for (uint32_t i = 0; i < staNodes.GetN(); ++i)
    {
        const uint32_t nodeId = staNodes.Get(i)->GetId();

        m_retriesPerNode[nodeId] = 0;
        m_attemptsPerNode[nodeId] = 0;
    }

    Config::Connect(
        "/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Phy/PhyTxBegin",
        MakeCallback(&MacRetryCounter::Trace, this));
}

void
MacRetryCounter::Trace(std::string context,
                       Ptr<const Packet> packet,
                       double txPowerW)
{
    (void)txPowerW;

    WifiMacHeader hdr;

    Ptr<Packet> copy = packet->Copy();

    if (copy->PeekHeader(hdr) == 0)
    {
        return;
    }

    if (!hdr.IsData())
    {
        return;
    }

    const std::string prefix = "/NodeList/";

    const std::size_t start = context.find(prefix);

    if (start == std::string::npos)
    {
        return;
    }

    const std::size_t idStart = start + prefix.size();

    const std::size_t idEnd = context.find('/', idStart);

    if (idEnd == std::string::npos)
    {
        return;
    }

    uint32_t nodeId = 0;

    try
    {
        nodeId = static_cast<uint32_t>(
            std::stoul(context.substr(idStart, idEnd - idStart)));
    }
    catch (const std::exception&)
    {
        return;
    }

    // Ignore transmissions from nodes we're not tracking (i.e. the AP).
    auto attemptIt = m_attemptsPerNode.find(nodeId);

    if (attemptIt == m_attemptsPerNode.end())
    {
        return;
    }

    ++attemptIt->second;

    if (hdr.IsRetry())
    {
        ++m_retriesPerNode[nodeId];
    }
}

uint64_t
MacRetryCounter::GetRetriesForNode(uint32_t nodeId) const
{
    auto it = m_retriesPerNode.find(nodeId);

    return (it == m_retriesPerNode.end()) ? 0 : it->second;
}

uint64_t
MacRetryCounter::GetAttemptsForNode(uint32_t nodeId) const
{
    auto it = m_attemptsPerNode.find(nodeId);

    return (it == m_attemptsPerNode.end()) ? 0 : it->second;
}

/*
 * --------------------------------------------------------------------------
 * P-EDCA DS-CTS counter
 * --------------------------------------------------------------------------
 *
 * Connects to the patch's Txop::PsrcTrace trace source on every station's
 * AC_VO EDCAF and counts DS-CTS transmissions per node. PsrcTrace fires on
 * BOTH increments (a DS-CTS was actually sent -- see
 * QosFrameExchangeManager::SendPedcaDsCts) and resets to 0 (successful Ack
 * or dropped MPDU -- see Txop::ResetPsrc / its call sites); a reset alone,
 * with no prior increment, is not a DS-CTS. This class tracks the last
 * value seen per node so only genuine increments are counted, which also
 * makes it safe to connect on every station: AC_VO_LEGACY stations never
 * increment (PedcaEligible() is false for them), so they contribute 0.
 */

class PedcaDsCtsCounter
{
  public:
    void Connect(NodeContainer staNodes);

    void Trace(std::string context, uint32_t newPsrc, uint8_t linkId);

    uint64_t GetDsCtsForNode(uint32_t nodeId) const;

  private:
    std::map<uint32_t, uint64_t> m_dsCtsPerNode;
    std::map<uint32_t, uint32_t> m_lastPsrcPerNode;
};

void
PedcaDsCtsCounter::Connect(NodeContainer staNodes)
{
    for (uint32_t i = 0; i < staNodes.GetN(); ++i)
    {
        const uint32_t nodeId = staNodes.Get(i)->GetId();

        m_dsCtsPerNode[nodeId] = 0;
        m_lastPsrcPerNode[nodeId] = 0;
    }

    Config::Connect("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PsrcTrace",
                     MakeCallback(&PedcaDsCtsCounter::Trace, this));
}

void
PedcaDsCtsCounter::Trace(std::string context, uint32_t newPsrc, uint8_t linkId)
{
    (void)linkId;

    const std::string prefix = "/NodeList/";

    const std::size_t start = context.find(prefix);

    if (start == std::string::npos)
    {
        return;
    }

    const std::size_t idStart = start + prefix.size();

    const std::size_t idEnd = context.find('/', idStart);

    if (idEnd == std::string::npos)
    {
        return;
    }

    uint32_t nodeId = 0;

    try
    {
        nodeId = static_cast<uint32_t>(std::stoul(context.substr(idStart, idEnd - idStart)));
    }
    catch (const std::exception&)
    {
        return;
    }

    auto lastIt = m_lastPsrcPerNode.find(nodeId);

    if (lastIt == m_lastPsrcPerNode.end())
    {
        return; // node we're not tracking (shouldn't happen: AP has no VO_Txop of interest)
    }

    if (newPsrc > lastIt->second)
    {
        // PSRC only ever increases by IncrementPsrc() (a DS-CTS just went out) or drops to 0
        // via ResetPsrc(); an increase is unambiguously a DS-CTS transmission.
        ++m_dsCtsPerNode[nodeId];
    }

    lastIt->second = newPsrc;
}

uint64_t
PedcaDsCtsCounter::GetDsCtsForNode(uint32_t nodeId) const
{
    auto it = m_dsCtsPerNode.find(nodeId);

    return (it == m_dsCtsPerNode.end()) ? 0 : it->second;
}

/*
 * --------------------------------------------------------------------------
 * MAIN
 * --------------------------------------------------------------------------
 */

int
main(int argc, char* argv[])
{
    // ======================================================================
    // Experiment parameters
    // ======================================================================

    /*
     * Per-AC station counts. AC_VO is split into legacy/P-EDCA
     * sub-populations; defaults reproduce a 6-station-per-group
     * baseline (N=24) with a 50/50 VO adoption split.
     */
    uint32_t nBe = 6;
    uint32_t nBk = 6;
    uint32_t nVi = 6;
    uint32_t nVoLegacy = 3;
    uint32_t nVoPedca = 3;

    uint32_t payloadSize = 1024;

    /*
     * P-EDCA (IEEE 802.11bn) parameters, applied to every station's
     * AC_VO EDCAF via Config::Set. Inert on AC_VO_LEGACY stations.
     * Defaults mirror the QosTxop attribute defaults in the patch --
     * verify against your target draft before publishing results.
     */
    uint32_t pedcaQsrcThreshold = 1;
    uint32_t pedcaPsrcThreshold = 1;
    uint32_t pedcaDsAifsn = 2;
    uint32_t pedcaCwDs = 0; // DS-CTS CWmin = CWmax = 0 (3 is reserved by the draft -- see validation below)
    uint32_t pedcaStage2Aifsn = 1;
    uint32_t pedcaStage2CwMin = 3;
    uint32_t pedcaStage2CwMax = 7;
    double pedcaStage2WindowUs = 97.0;

    /*
     * Per-AC offered load in Mbit/s. Held FIXED per AC by default
     * (see file header comment): each AC's total demand stays at
     * perAcLoadMbps regardless of how many stations are assigned to
     * it, isolating station-count/contention effects.
     */
    double perAcLoadMbps = 2.0;

    /*
     * Alternate policy: fix load PER STATION instead of per AC, so
     * an AC's total demand scales with how many stations it has.
     * perStationLoadMbps is only used when this flag is true.
     */
    bool perStationLoadFixed = false;

    double perStationLoadMbpsFixed = 0.25;

    double simulationTime = 60.0;

    double warmupTime = 5.0;

    double drainTime = 5.0;

    double bssRadius = 5.0;

    uint32_t rngSeed = 1;

    uint32_t rngRun = 1;

    bool enablePcap = false;

    std::string scenarioLabel = "custom";

    std::string outputCsv = "results/edca_ratio.csv";

    std::string pcapDirectory = "results/pcap";

    // ======================================================================
    // Command line
    // ======================================================================

    CommandLine cmd(__FILE__);

    cmd.AddValue("nBe", "Number of AC_BE stations", nBe);
    cmd.AddValue("nBk", "Number of AC_BK stations", nBk);
    cmd.AddValue("nVi", "Number of AC_VI stations", nVi);
    cmd.AddValue("nVoLegacy", "Number of legacy (non-P-EDCA) AC_VO stations", nVoLegacy);
    cmd.AddValue("nVoPedca", "Number of P-EDCA-enabled AC_VO stations", nVoPedca);

    cmd.AddValue("pedcaQsrcThreshold",
                 "P-EDCA: minimum QSRC for AC_VO to be P-EDCA eligible",
                 pedcaQsrcThreshold);
    cmd.AddValue("pedcaPsrcThreshold", "P-EDCA: PSRC limit (1-4)", pedcaPsrcThreshold);
    cmd.AddValue("pedcaDsAifsn", "P-EDCA: AIFSN while contending to send a DS-CTS", pedcaDsAifsn);
    cmd.AddValue("pedcaCwDs", "P-EDCA: CW_DS, max backoff window for the DS-CTS attempt", pedcaCwDs);
    cmd.AddValue("pedcaStage2Aifsn", "P-EDCA: AIFSN inside Stage 2", pedcaStage2Aifsn);
    cmd.AddValue("pedcaStage2CwMin", "P-EDCA: minimum CW inside Stage 2", pedcaStage2CwMin);
    cmd.AddValue("pedcaStage2CwMax", "P-EDCA: maximum CW inside Stage 2", pedcaStage2CwMax);
    cmd.AddValue("pedcaStage2WindowUs",
                 "P-EDCA: Stage-2 window / DS-CTS Duration, in microseconds",
                 pedcaStage2WindowUs);

    cmd.AddValue("payloadSize", "UDP payload size in bytes", payloadSize);

    cmd.AddValue(
        "perAcLoadMbps",
        "Fixed total offered load per AC in Mbit/s (used unless "
        "--perStationLoadFixed=1)",
        perAcLoadMbps);

    cmd.AddValue(
        "perStationLoadFixed",
        "If true, fix load per STATION instead of per AC "
        "(total AC demand then scales with station count)",
        perStationLoadFixed);

    cmd.AddValue(
        "perStationLoadMbpsFixed",
        "Per-station offered load in Mbit/s, used only when "
        "--perStationLoadFixed=1",
        perStationLoadMbpsFixed);

    cmd.AddValue("simulationTime", "Measurement window in seconds", simulationTime);
    cmd.AddValue("warmupTime", "Traffic warm-up time in seconds", warmupTime);
    cmd.AddValue("drainTime", "Post-traffic drain time in seconds", drainTime);
    cmd.AddValue("bssRadius", "STA placement disc radius in metres", bssRadius);

    cmd.AddValue("rngSeed", "RngSeed value", rngSeed);
    cmd.AddValue("rngRun", "RngRun index", rngRun);

    cmd.AddValue("enablePcap", "Enable PCAP capture", enablePcap);

    cmd.AddValue(
        "scenarioLabel",
        "Free-text label identifying this scenario row (e.g. "
        "'VO-heavy'), written to the CSV for easy filtering",
        scenarioLabel);

    cmd.AddValue("outputCsv", "CSV output file", outputCsv);
    cmd.AddValue("pcapDirectory", "PCAP output directory", pcapDirectory);

    cmd.Parse(argc, argv);

    // ======================================================================
    // Validation
    // ======================================================================

    if (nBe == 0 || nBk == 0 || nVi == 0)
    {
        NS_FATAL_ERROR("nBe, nBk, nVi must all be > 0 (every non-VO AC needs at "
                        "least one station)");
    }

    if (nVoLegacy + nVoPedca == 0)
    {
        NS_FATAL_ERROR("nVoLegacy + nVoPedca must be > 0 (AC_VO needs at least one "
                        "station; this is the whole point of the ratio being tested, so "
                        "nVoLegacy=0 or nVoPedca=0 alone -- a 0%/100% adoption point -- "
                        "is fine and expected)");
    }

    if (pedcaPsrcThreshold < 1 || pedcaPsrcThreshold > 4)
    {
        NS_FATAL_ERROR("pedcaPsrcThreshold must be in [1,4] (0 is reserved by the draft)");
    }

    if (pedcaCwDs == 3)
    {
        NS_FATAL_ERROR("pedcaCwDs=3 is reserved by the draft; verify the value you intend "
                        "against the draft before overriding this check");
    }

    if (pedcaStage2WindowUs <= 0.0)
    {
        NS_FATAL_ERROR("pedcaStage2WindowUs must be > 0");
    }

    if (payloadSize == 0)
    {
        NS_FATAL_ERROR("payloadSize must be > 0");
    }

    if (perAcLoadMbps <= 0.0)
    {
        NS_FATAL_ERROR("perAcLoadMbps must be > 0");
    }

    if (perStationLoadFixed && perStationLoadMbpsFixed <= 0.0)
    {
        NS_FATAL_ERROR("perStationLoadMbpsFixed must be > 0");
    }

    if (simulationTime <= 0.0)
    {
        NS_FATAL_ERROR("simulationTime must be > 0");
    }

    if (warmupTime < 0.0)
    {
        NS_FATAL_ERROR("warmupTime must be >= 0");
    }

    if (drainTime <= 0.0)
    {
        NS_FATAL_ERROR("drainTime must be > 0");
    }

    if (bssRadius <= 0.0)
    {
        NS_FATAL_ERROR("bssRadius must be > 0");
    }

    const uint32_t numStations = nBe + nBk + nVi + nVoLegacy + nVoPedca;

    // Per-AC station counts, indexed to match kAcGroups
    // (0=BE,1=BK,2=VI,3=VO_LEGACY,4=VO_PEDCA)
    const std::array<uint32_t, 5> stationsPerAc = {nBe, nBk, nVi, nVoLegacy, nVoPedca};

    const uint32_t nVoTotal = nVoLegacy + nVoPedca;
    const double pedcaAdoptionRatio =
        nVoTotal > 0 ? static_cast<double>(nVoPedca) / static_cast<double>(nVoTotal) : 0.0;

    // ======================================================================
    // Randomness
    // ======================================================================

    RngSeedManager::SetSeed(rngSeed);
    RngSeedManager::SetRun(rngRun);

    const double trafficStart = warmupTime;
    const double trafficStop = trafficStart + simulationTime;
    const double simulationStop = trafficStop + drainTime;

    // ======================================================================
    // Nodes
    // ======================================================================

    NodeContainer apNode;
    apNode.Create(1);

    NodeContainer staNodes;
    staNodes.Create(numStations);

    // ======================================================================
    // PHY and channel
    // ======================================================================

    YansWifiChannelHelper channel;

    channel.SetPropagationDelay("ns3::ConstantSpeedPropagationDelayModel");

    channel.AddPropagationLoss(
        "ns3::FriisPropagationLossModel",
        "Frequency",
        DoubleValue(5.18e9));

    YansWifiPhyHelper phy;

    phy.SetChannel(channel.Create());

    phy.SetPcapDataLinkType(WifiPhyHelper::DLT_IEEE802_11_RADIO);

    // Channel 36: 5 GHz, 20 MHz
    phy.Set("ChannelSettings", StringValue("{36, 20, BAND_5GHZ, 0}"));

    // ======================================================================
    // Wi-Fi configuration
    // ======================================================================

    WifiHelper wifi;

    wifi.SetStandard(WIFI_STANDARD_80211a);

    wifi.SetRemoteStationManager(
        "ns3::ConstantRateWifiManager",
        "DataMode",
        StringValue("OfdmRate54Mbps"),
        "ControlMode",
        StringValue("OfdmRate24Mbps"));

    WifiMacHelper mac;

    const Ssid ssid("pedca-ratio");

    /*
     * STA MAC, installed in 5 contiguous per-group slices matching
     * kAcGroups / GroupForStation() exactly. Every group gets
     * QosSupported=true; only the AC_VO_PEDCA slice additionally gets
     * PEdcaSupported=true (construction-only attribute, per the patch,
     * so it must be set here rather than after Install()).
     *
     * NetDeviceContainer::Add() below preserves index order as long as
     * these five Install() calls run in ascending staNodes index order,
     * which they do (BE, BK, VI, VO_LEGACY, VO_PEDCA), so
     * staDevices.Get(i) still corresponds to staNodes.Get(i) afterwards.
     */
    NetDeviceContainer staDevices;

    uint32_t staOffset = 0;

    for (int g = 0; g < 5; ++g)
    {
        const uint32_t n = stationsPerAc[g];

        if (n == 0)
        {
            continue; // e.g. nVoLegacy=0 at the 100%-adoption end of the ratio sweep
        }

        NodeContainer slice;

        for (uint32_t i = staOffset; i < staOffset + n; ++i)
        {
            slice.Add(staNodes.Get(i));
        }

        staOffset += n;

        mac.SetType("ns3::StaWifiMac",
                    "QosSupported",
                    BooleanValue(true),
                    "PEdcaSupported",
                    BooleanValue(kAcGroups[g].pedcaCapable),
                    "Ssid",
                    SsidValue(ssid),
                    "ActiveProbing",
                    BooleanValue(false));

        staDevices.Add(wifi.Install(phy, mac, slice));
    }

    NS_ABORT_MSG_IF(staOffset != numStations,
                    "Per-group slice offsets did not add up to numStations; "
                    "check stationsPerAc/kAcGroups ordering");

    // AP MAC. PEdcaSupported left at its default (false): this scenario is
    // uplink-only, so the AP never itself contends as a P-EDCA STA; it still
    // correctly runs the receive-side DS-CTS/NAV logic for any P-EDCA STA
    // that overhears it, since that logic lives in QosFrameExchangeManager
    // and applies regardless of PEdcaSupported on the receiving MAC.
    mac.SetType(
        "ns3::ApWifiMac",
        "QosSupported",
        BooleanValue(true),
        "Ssid",
        SsidValue(ssid),
        "EnableBeaconJitter",
        BooleanValue(false));

    NetDeviceContainer apDevice = wifi.Install(phy, mac, apNode);

    // ======================================================================
    // P-EDCA attributes
    // ======================================================================
    //
    // Applied to every station's (and the AP's) AC_VO EDCAF. Inert on
    // AC_VO_LEGACY stations and on the AP, since PedcaEligible() checks
    // GetPEdcaSupported() first; only the AC_VO_PEDCA sub-group's values
    // actually drive behaviour. Set globally anyway, matching the draft's
    // own model of the AP distributing these as a single IE to the BSS.

    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaQsrcThreshold",
                UintegerValue(pedcaQsrcThreshold));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaPsrcThreshold",
                UintegerValue(pedcaPsrcThreshold));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaDsAifsn",
                UintegerValue(pedcaDsAifsn));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaCwDs",
                UintegerValue(pedcaCwDs));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaStage2Aifsn",
                UintegerValue(pedcaStage2Aifsn));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaStage2CwMin",
                UintegerValue(pedcaStage2CwMin));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaStage2CwMax",
                UintegerValue(pedcaStage2CwMax));
    Config::Set("/NodeList/*/DeviceList/*/$ns3::WifiNetDevice/Mac/VO_Txop/PEdcaStage2Window",
                TimeValue(MicroSeconds(pedcaStage2WindowUs)));

    // ======================================================================
    // Mobility
    // ======================================================================

    MobilityHelper apMobility;

    Ptr<ListPositionAllocator> apPosition = CreateObject<ListPositionAllocator>();

    apPosition->Add(Vector(0.0, 0.0, 0.0));

    apMobility.SetPositionAllocator(apPosition);
    apMobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    apMobility.Install(apNode);

    MobilityHelper staMobility;

    Ptr<UniformDiscPositionAllocator> staAllocator =
        CreateObject<UniformDiscPositionAllocator>();

    staAllocator->SetX(0.0);
    staAllocator->SetY(0.0);
    staAllocator->SetZ(0.0);
    staAllocator->SetRho(bssRadius);

    // Must be assigned before Install(); positions are drawn during install.
    staAllocator->AssignStreams(1000);

    staMobility.SetPositionAllocator(staAllocator);
    staMobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    staMobility.Install(staNodes);

    // ======================================================================
    // Internet stack
    // ======================================================================

    InternetStackHelper stack;

    stack.Install(apNode);
    stack.Install(staNodes);

    // ======================================================================
    // IP addressing
    // ======================================================================

    Ipv4AddressHelper address;

    address.SetBase("192.168.1.0", "255.255.255.0");

    Ipv4InterfaceContainer apInterface = address.Assign(apDevice);
    Ipv4InterfaceContainer staInterfaces = address.Assign(staDevices);

    // ======================================================================
    // Create STA -> AC mappings
    // ======================================================================

    std::map<uint32_t, int> nodeIdToGroup;
    std::map<Ipv4Address, int> addressToGroup;

    for (uint32_t i = 0; i < numStations; ++i)
    {
        const int group = GroupForStation(i, nBe, nBk, nVi, nVoLegacy, nVoPedca);

        const uint32_t nodeId = staNodes.Get(i)->GetId();
        const Ipv4Address sourceAddress = staInterfaces.GetAddress(i);

        nodeIdToGroup[nodeId] = group;
        addressToGroup[sourceAddress] = group;
    }

    // ======================================================================
    // Per-AC / per-station load calculation
    // ======================================================================

    // perStationLoadMbps[g] = individual rate for every station in group g
    std::array<double, 5> perStationLoadMbps{};

    // Actual total demand per AC (may differ from perAcLoadMbps if using
    // the fixed-per-station policy).
    std::array<double, 5> actualPerAcLoadMbps{};

    for (int g = 0; g < 5; ++g)
    {
        const uint32_t n = stationsPerAc[g];

        if (n == 0)
        {
            continue; // e.g. nVoLegacy=0 or nVoPedca=0 at the ends of the adoption sweep
        }

        // Groups 3 (VO_LEGACY) and 4 (VO_PEDCA) share ONE real AC_VO with ONE combined
        // demand: dividing perAcLoadMbps by each sub-group's own count independently would
        // double AC_VO's effective total load (once per sub-group) instead of holding it
        // fixed while the adoption ratio varies, which is the whole point of this test.
        const uint32_t nForFixedAcTotal = (g == 3 || g == 4) ? nVoTotal : n;

        if (perStationLoadFixed)
        {
            perStationLoadMbps[g] = perStationLoadMbpsFixed;
            actualPerAcLoadMbps[g] = perStationLoadMbpsFixed * static_cast<double>(n);
        }
        else
        {
            perStationLoadMbps[g] = perAcLoadMbps / static_cast<double>(nForFixedAcTotal);
            actualPerAcLoadMbps[g] = perAcLoadMbps / static_cast<double>(nForFixedAcTotal) *
                                      static_cast<double>(n);
        }
    }

    // ======================================================================
    // Burst traffic model
    // ======================================================================
    //
    // Each station alternates between an ON period of fixed duration and an
    // OFF period drawn from Exponential(mean burstOffTimeMeanSeconds) -- a
    // standard bursty-source renewal model. OnOffHelper's DataRate is the
    // rate applied WHILE ON, not a time-average, so a station transmitting
    // at rateBps only for a dutyCycle fraction of the run delivers a
    // time-averaged offered load of rateBps * dutyCycle, not rateBps. The
    // ON-period rate used below is scaled up by 1/dutyCycle so that the
    // time-average still equals perStationLoadMbps[g] / perAcOfferedLoadMbps[g]
    // (and the CSV columns of the same names), matching what those numbers
    // meant in the original CBR sweep.

    const double burstOnTimeSeconds = 1.0;
    const double burstOffTimeMeanSeconds = 2.0;
    const double dutyCycle =
        burstOnTimeSeconds / (burstOnTimeSeconds + burstOffTimeMeanSeconds);

    // ======================================================================
    // Print configuration
    // ======================================================================

    std::cout << "\n";
    std::cout << "=============================================\n";
    std::cout << "     P-EDCA ADOPTION-RATIO VALIDATION\n";
    std::cout << "=============================================\n";

    std::cout << "Scenario label:       " << scenarioLabel << "\n";
    std::cout << "Total stations:       " << numStations << "\n";
    std::cout << "AC_VO total / adopt:  " << nVoTotal << " stations, "
              << (pedcaAdoptionRatio * 100.0) << "% P-EDCA\n";
    std::cout << "Load policy:          "
              << (perStationLoadFixed ? "fixed per-station" : "fixed per-AC")
              << "\n";
    std::cout << "RngSeed:              " << rngSeed << "\n";
    std::cout << "RngRun:               " << rngRun << "\n";

    std::cout << "\nP-EDCA parameters (AC_VO EDCAF, applied station-wide):\n";
    std::cout << "  QSRC threshold:     " << pedcaQsrcThreshold << "\n";
    std::cout << "  PSRC threshold:     " << pedcaPsrcThreshold << "\n";
    std::cout << "  DS AIFSN / CW_DS:   " << pedcaDsAifsn << " / " << pedcaCwDs << "\n";
    std::cout << "  Stage-2 AIFSN:      " << pedcaStage2Aifsn << "\n";
    std::cout << "  Stage-2 CWmin/max:  " << pedcaStage2CwMin << " / " << pedcaStage2CwMax
              << "\n";
    std::cout << "  Stage-2 window:     " << pedcaStage2WindowUs << " us\n";

    std::cout << "\nTraffic model:        burst (ON=" << burstOnTimeSeconds
              << "s constant, OFF=Exp(mean=" << burstOffTimeMeanSeconds
              << "s)), duty cycle " << (dutyCycle * 100.0) << "%\n";
    std::cout << "  ON-period rate is scaled by 1/dutyCycle so the time-averaged\n";
    std::cout << "  offered load matches perStationLoadMbps/perAcOfferedLoadMbps below.\n";

    std::cout << "\nAC assignment (stations / per-station Mbps / total AC Mbps):\n";

    for (int g = 0; g < 5; ++g)
    {
        std::cout << "  " << kAcGroups[g].label << " : "
                  << stationsPerAc[g] << " stations, "
                  << perStationLoadMbps[g] << " Mbps/STA, "
                  << actualPerAcLoadMbps[g] << " Mbps total\n";
    }

    std::cout << "=============================================\n\n";

    // ======================================================================
    // UDP server
    // ======================================================================

    const uint16_t port = 5000;

    UdpServerHelper server(port);

    ApplicationContainer serverApp = server.Install(apNode.Get(0));

    serverApp.Start(Seconds(0.0));
    serverApp.Stop(Seconds(simulationStop));

    // ======================================================================
    // UDP traffic
    // ======================================================================

    const InetSocketAddress dest(apInterface.GetAddress(0), port);

    for (uint32_t i = 0; i < numStations; ++i)
    {
        const int group = GroupForStation(i, nBe, nBk, nVi, nVoLegacy, nVoPedca);

        const uint64_t rateBps = static_cast<uint64_t>(
            std::llround(perStationLoadMbps[group] * 1'000'000.0 / dutyCycle));

        OnOffHelper client("ns3::UdpSocketFactory", dest);

        client.SetConstantRate(DataRate(rateBps), payloadSize);

        client.SetAttribute("Tos", UintegerValue(kAcGroups[group].tos));

        client.SetAttribute(
            "OnTime",
            StringValue("ns3::ConstantRandomVariable[Constant=" +
                         std::to_string(burstOnTimeSeconds) + "]"));
        client.SetAttribute(
            "OffTime",
            StringValue("ns3::ExponentialRandomVariable[Mean=" +
                         std::to_string(burstOffTimeMeanSeconds) + "]"));

        ApplicationContainer app = client.Install(staNodes.Get(i));

        app.Start(Seconds(trafficStart));
        app.Stop(Seconds(trafficStop));
    }

    // ======================================================================
    // PCAP
    // ======================================================================

    if (enablePcap)
    {
        std::filesystem::create_directories(pcapDirectory);

        const std::string prefix = pcapDirectory + "/edca-ratio-" +
                                    scenarioLabel + "-run" +
                                    std::to_string(rngRun);

        phy.EnablePcap(prefix + "-ap", apDevice.Get(0));

        for (uint32_t i = 0; i < staDevices.GetN(); ++i)
        {
            phy.EnablePcap(prefix + "-sta" + std::to_string(i), staDevices.Get(i));
        }
    }

    // ======================================================================
    // FlowMonitor
    // ======================================================================

    FlowMonitorHelper flowmonHelper;

    Ptr<FlowMonitor> monitor = flowmonHelper.InstallAll();

    monitor->SetAttribute("StartTime", TimeValue(Seconds(0.0)));
    monitor->SetAttribute("MaxPerHopDelay", TimeValue(Seconds(drainTime)));

    // ======================================================================
    // MAC retry counter
    // ======================================================================

    MacRetryCounter retryCounter;

    retryCounter.Connect(staNodes);

    PedcaDsCtsCounter dsCtsCounter;

    dsCtsCounter.Connect(staNodes);

    // ======================================================================
    // Simulation
    // ======================================================================

    Simulator::Stop(Seconds(simulationStop));
    Simulator::Run();

    // ======================================================================
    // FlowMonitor finalization
    // ======================================================================

    monitor->CheckForLostPackets(Seconds(drainTime));

    Ptr<Ipv4FlowClassifier> classifier =
        DynamicCast<Ipv4FlowClassifier>(flowmonHelper.GetClassifier());

    const FlowMonitor::FlowStatsContainer stats = monitor->GetFlowStats();

    // ======================================================================
    // Per-AC statistics structure
    // ======================================================================

    struct GroupAggregate
    {
        uint64_t txPackets = 0;
        uint64_t rxPackets = 0;
        uint64_t txBytes = 0;
        uint64_t rxBytes = 0;
        uint64_t lostPackets = 0;
        uint64_t jitterSamples = 0;
        double delaySum = 0.0;
        double jitterSum = 0.0;
    };

    std::array<GroupAggregate, 5> perGroup{};

    for (const auto& flow : stats)
    {
        const FlowId flowId = flow.first;

        const auto tuple = classifier->FindFlow(flowId);

        if (tuple.protocol != 17 || tuple.destinationAddress != apInterface.GetAddress(0))
        {
            continue;
        }

        auto groupIt = addressToGroup.find(tuple.sourceAddress);

        if (groupIt == addressToGroup.end())
        {
            continue;
        }

        const int group = groupIt->second;

        GroupAggregate& agg = perGroup[group];

        const auto& s = flow.second;

        agg.txPackets += s.txPackets;
        agg.rxPackets += s.rxPackets;
        agg.txBytes += s.txBytes;
        agg.rxBytes += s.rxBytes;
        agg.lostPackets += s.lostPackets;
        agg.delaySum += s.delaySum.GetSeconds();
        agg.jitterSum += s.jitterSum.GetSeconds();

        if (s.rxPackets > 1)
        {
            agg.jitterSamples += static_cast<uint64_t>(s.rxPackets - 1);
        }
    }

    // ======================================================================
    // Calculate per-AC MAC attempts/retries
    // ======================================================================

    std::array<uint64_t, 5> macAttemptsPerGroup{};
    std::array<uint64_t, 5> macRetriesPerGroup{};
    std::array<uint64_t, 5> dsCtsPerGroup{}; // nonzero only for group 4, AC_VO_PEDCA

    for (uint32_t i = 0; i < numStations; ++i)
    {
        const int group = GroupForStation(i, nBe, nBk, nVi, nVoLegacy, nVoPedca);

        const uint32_t nodeId = staNodes.Get(i)->GetId();

        macAttemptsPerGroup[group] += retryCounter.GetAttemptsForNode(nodeId);
        macRetriesPerGroup[group] += retryCounter.GetRetriesForNode(nodeId);
        dsCtsPerGroup[group] += dsCtsCounter.GetDsCtsForNode(nodeId);
    }

    // ======================================================================
    // Output header
    // ======================================================================

    std::cout << std::fixed << std::setprecision(6);

    std::cout << "\n";
    std::cout << "=============================================\n";
    std::cout << "     P-EDCA RATIO RESULTS - FOUR ACs + VO SPLIT\n";
    std::cout << "=============================================\n";

    // ======================================================================
    // CSV directory
    // ======================================================================

    const std::filesystem::path csvPath(outputCsv);

    if (!csvPath.parent_path().empty())
    {
        std::filesystem::create_directories(csvPath.parent_path());
    }

    const bool fileExists =
        std::filesystem::exists(csvPath) && std::filesystem::file_size(csvPath) > 0;

    std::ofstream csv(outputCsv, std::ios::app);

    if (!csv)
    {
        NS_FATAL_ERROR("Could not open CSV output file: " << outputCsv);
    }

    // ======================================================================
    // CSV header
    // ======================================================================

    if (!fileExists)
    {
        csv << "protocol,"
            << "scenarioLabel,"
            << "ac,"
            << "numStations,"
            << "nBe,"
            << "nBk,"
            << "nVi,"
            << "nVoLegacy,"
            << "nVoPedca,"
            << "pedcaAdoptionRatio,"
            << "stationsInAc,"
            << "bssRadius,"
            << "loadPolicy,"
            << "perStationLoadMbps,"
            << "perAcOfferedLoadMbps,"
            << "payloadSize,"
            << "phyDataRateMbps,"
            << "phyControlRateMbps,"
            << "simulationTime,"
            << "warmupTime,"
            << "drainTime,"
            << "rngSeed,"
            << "rngRun,"
            << "pedcaQsrcThreshold,"
            << "pedcaPsrcThreshold,"
            << "pedcaDsAifsn,"
            << "pedcaCwDs,"
            << "pedcaStage2Aifsn,"
            << "pedcaStage2CwMin,"
            << "pedcaStage2CwMax,"
            << "pedcaStage2WindowUs,"
            << "throughputMbps,"
            << "payloadGoodputMbps,"
            << "pdr,"
            << "packetLossRate,"
            << "meanDelayMs,"
            << "meanJitterMs,"
            << "jitterSamples,"
            << "txPackets,"
            << "rxPackets,"
            << "txBytes,"
            << "rxBytes,"
            << "flowMonitorLostPackets,"
            << "macDataAttempts,"
            << "macRetransmissions,"
            << "dsCtsTransmissions,"
            << "pcapEnabled\n";
    }

    // ======================================================================
    // Write one row for each AC
    // ======================================================================

    for (int g = 0; g < 5; ++g)
    {
        const GroupAggregate& agg = perGroup[g];

        const double throughputMbps =
            (static_cast<double>(agg.rxBytes) * 8.0) / (simulationTime * 1'000'000.0);

        const double payloadGoodputMbps =
            (static_cast<double>(agg.rxPackets) * static_cast<double>(payloadSize) * 8.0) /
            (simulationTime * 1'000'000.0);

        const double pdr = agg.txPackets > 0
                                ? static_cast<double>(agg.rxPackets) /
                                      static_cast<double>(agg.txPackets)
                                : 0.0;

        const double packetLossRate = agg.txPackets > 0 ? 1.0 - pdr : 0.0;

        const double meanDelayMs =
            agg.rxPackets > 0
                ? (agg.delaySum / static_cast<double>(agg.rxPackets)) * 1000.0
                : std::numeric_limits<double>::quiet_NaN();

        const double meanJitterMs =
            agg.jitterSamples > 0
                ? (agg.jitterSum / static_cast<double>(agg.jitterSamples)) * 1000.0
                : std::numeric_limits<double>::quiet_NaN();

        const uint64_t macAttempts = macAttemptsPerGroup[g];
        const uint64_t macRetries = macRetriesPerGroup[g];
        const uint64_t dsCtsCount = dsCtsPerGroup[g];

        std::cout << "\n--- " << kAcGroups[g].label << " (" << stationsPerAc[g]
                  << " STAs) ---\n";
        std::cout << "  Offered load (this group): " << actualPerAcLoadMbps[g] << " Mbps\n";
        std::cout << "  TX packets:           " << agg.txPackets << "\n";
        std::cout << "  RX packets:           " << agg.rxPackets << "\n";
        std::cout << "  IP throughput:        " << throughputMbps << " Mbps\n";
        std::cout << "  Payload goodput:      " << payloadGoodputMbps << " Mbps\n";
        std::cout << "  PDR:                  " << pdr * 100.0 << " %\n";
        std::cout << "  Packet loss rate:     " << packetLossRate * 100.0 << " %\n";
        std::cout << "  Mean delay:           " << meanDelayMs << " ms\n";
        std::cout << "  Mean jitter:          " << meanJitterMs << " ms\n";
        std::cout << "  MAC data attempts:    " << macAttempts << "\n";
        std::cout << "  MAC retransmissions:  " << macRetries << "\n";
        std::cout << "  DS-CTS transmissions: " << dsCtsCount << "\n";

        if (agg.rxPackets > agg.txPackets)
        {
            NS_LOG_WARN("RX packets exceed TX packets for " << kAcGroups[g].label);
        }

        if (macRetries > macAttempts)
        {
            NS_LOG_WARN("MAC retries exceed attempts for " << kAcGroups[g].label);
        }

        if (dsCtsCount > 0 && !kAcGroups[g].pedcaCapable)
        {
            // Should be structurally impossible (PedcaEligible() checks
            // GetPEdcaSupported() first), so treat it as a modelling bug if seen.
            NS_LOG_WARN("Non-P-EDCA group " << kAcGroups[g].label
                                            << " recorded DS-CTS transmissions: "
                                            << dsCtsCount);
        }

        csv << "EDCA," << scenarioLabel << ',' << kAcGroups[g].label << ',' << numStations
            << ',' << nBe << ',' << nBk << ',' << nVi << ',' << nVoLegacy << ',' << nVoPedca
            << ',' << pedcaAdoptionRatio << ',' << stationsPerAc[g] << ',' << bssRadius
            << ',' << (perStationLoadFixed ? "perStation" : "perAc") << ','
            << perStationLoadMbps[g] << ',' << actualPerAcLoadMbps[g] << ','
            << payloadSize << ',' << 54 << ',' << 24 << ',' << simulationTime << ','
            << warmupTime << ',' << drainTime << ',' << rngSeed << ',' << rngRun << ','
            << pedcaQsrcThreshold << ',' << pedcaPsrcThreshold << ',' << pedcaDsAifsn << ','
            << pedcaCwDs << ',' << pedcaStage2Aifsn << ',' << pedcaStage2CwMin << ','
            << pedcaStage2CwMax << ',' << pedcaStage2WindowUs << ','
            << throughputMbps << ',' << payloadGoodputMbps << ',' << pdr << ','
            << packetLossRate << ',' << meanDelayMs << ',' << meanJitterMs << ','
            << agg.jitterSamples << ',' << agg.txPackets << ',' << agg.rxPackets << ','
            << agg.txBytes << ',' << agg.rxBytes << ',' << agg.lostPackets << ','
            << macAttempts << ',' << macRetries << ',' << dsCtsCount << ','
            << (enablePcap ? 1 : 0) << '\n';
    }

    csv.close();

    // ======================================================================
    // Finalize simulation
    // ======================================================================

    Simulator::Destroy();

    std::cout << "\nResults written to: " << outputCsv << "\n";

    return 0;
}