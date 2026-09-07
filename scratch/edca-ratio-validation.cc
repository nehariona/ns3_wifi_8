/*
 * EDCA station-ratio validation scenario for ns-3.48
 *
 * Purpose:
 *   Same single-BSS, uplink-only, four-AC EDCA baseline as
 *   edca-baseline-validation.cc, EXCEPT that the number of stations
 *   assigned to each Access Category is now independently controllable
 *   instead of being forced to an equal split of numStations.
 *
 *   This lets you hold total contention (total station count) fixed
 *   while varying how those stations are DISTRIBUTED across
 *   AC_VO / AC_VI / AC_BE / AC_BK, e.g.:
 *
 *       Baseline:            8 / 8 / 8 / 8    (N=32)
 *       VO-heavy:            20 / 4 / 4 / 4   (N=32)
 *       BK-heavy:            4 / 4 / 4 / 20   (N=32)
 *       Inverted pyramid:    2 / 4 / 10 / 16  (N=32)
 *       Pyramid:             4 / 8 / 8 / 12   (N=32)
 *       High-priority pol.:  14 / 14 / 2 / 2  (N=32)
 *       Low-priority pol.:   2 / 2 / 14 / 14  (N=32)
 *       Extreme single-STA:  1 / 1 / 1 / 29   (N=32)
 *
 * Offered load policy:
 *   FIXED PER-AC LOAD (default, recommended for this experiment).
 *
 *   Each AC's TOTAL offered load stays constant (perAcLoadMbps,
 *   default 2 Mbps) regardless of how many stations are in that AC.
 *   Each station's individual rate is:
 *
 *       perAcLoadMbps / stationsInThatAc
 *
 *   This isolates the effect of STATION-COUNT / CONTENTION per AC
 *   from the effect of TRAFFIC VOLUME per AC, which is the point of
 *   this experiment: "does adding more same-AC contenders change
 *   that AC's own behaviour, holding its total demand constant?"
 *
 *   A --perStationLoadFixed flag is provided to switch to the
 *   alternate policy (fixed load per STATION, so total AC demand
 *   scales with station count) if you want that comparison instead.
 *
 * FlowMonitor, MAC retry counting, RNG handling, and CSV structure
 * otherwise follow edca-baseline-validation.cc exactly.
 */

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
};

// Order here fixes group index: 0=BE, 1=BK, 2=VI, 3=VO
const std::array<AcGroup, 4> kAcGroups = {{
    {"AC_BE", 0x70},
    {"AC_BK", 0x28},
    {"AC_VI", 0xb8},
    {"AC_VO", 0xc0},
}};

/*
 * --------------------------------------------------------------------------
 * Station -> AC mapping (ratio-aware)
 * --------------------------------------------------------------------------
 *
 * Stations are laid out contiguously in the order:
 *
 *   [0 .. nBe)                    -> AC_BE
 *   [nBe .. nBe+nBk)               -> AC_BK
 *   [nBe+nBk .. nBe+nBk+nVi)       -> AC_VI
 *   [nBe+nBk+nVi .. numStations)   -> AC_VO
 *
 * numStations = nBe + nBk + nVi + nVo, computed by the caller.
 */

int
GroupForStation(uint32_t staIndex,
                uint32_t nBe,
                uint32_t nBk,
                uint32_t nVi,
                uint32_t nVo)
{
    (void)nVo; // last group absorbs the remainder; kept for clarity/symmetry

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

    return 3; // AC_VO
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
     * Per-AC station counts. Defaults reproduce the old equal-split
     * baseline (3 STAs/AC, N=12) for backward compatibility.
     */
    uint32_t nBe = 3;
    uint32_t nBk = 3;
    uint32_t nVi = 3;
    uint32_t nVo = 3;

    uint32_t payloadSize = 1024;

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
    cmd.AddValue("nVo", "Number of AC_VO stations", nVo);

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

    if (nBe == 0 || nBk == 0 || nVi == 0 || nVo == 0)
    {
        NS_FATAL_ERROR(
            "nBe, nBk, nVi, nVo must all be > 0 (every AC needs at "
            "least one station)");
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

    const uint32_t numStations = nBe + nBk + nVi + nVo;

    // Per-AC station counts, indexed to match kAcGroups (0=BE,1=BK,2=VI,3=VO)
    const std::array<uint32_t, 4> stationsPerAc = {nBe, nBk, nVi, nVo};

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

    const Ssid ssid("edca-ratio");

    // STA MAC
    mac.SetType(
        "ns3::StaWifiMac",
        "QosSupported",
        BooleanValue(true),
        "Ssid",
        SsidValue(ssid),
        "ActiveProbing",
        BooleanValue(false));

    NetDeviceContainer staDevices = wifi.Install(phy, mac, staNodes);

    // AP MAC
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
        const int group = GroupForStation(i, nBe, nBk, nVi, nVo);

        const uint32_t nodeId = staNodes.Get(i)->GetId();
        const Ipv4Address sourceAddress = staInterfaces.GetAddress(i);

        nodeIdToGroup[nodeId] = group;
        addressToGroup[sourceAddress] = group;
    }

    // ======================================================================
    // Per-AC / per-station load calculation
    // ======================================================================

    // perStationLoadMbps[g] = individual rate for every station in group g
    std::array<double, 4> perStationLoadMbps{};

    // Actual total demand per AC (may differ from perAcLoadMbps if using
    // the fixed-per-station policy).
    std::array<double, 4> actualPerAcLoadMbps{};

    for (int g = 0; g < 4; ++g)
    {
        const uint32_t n = stationsPerAc[g];

        if (perStationLoadFixed)
        {
            perStationLoadMbps[g] = perStationLoadMbpsFixed;
            actualPerAcLoadMbps[g] =
                perStationLoadMbpsFixed * static_cast<double>(n);
        }
        else
        {
            perStationLoadMbps[g] = perAcLoadMbps / static_cast<double>(n);
            actualPerAcLoadMbps[g] = perAcLoadMbps;
        }
    }

    // ======================================================================
    // Print configuration
    // ======================================================================

    std::cout << "\n";
    std::cout << "=============================================\n";
    std::cout << "     EDCA STATION-RATIO VALIDATION\n";
    std::cout << "=============================================\n";

    std::cout << "Scenario label:       " << scenarioLabel << "\n";
    std::cout << "Total stations:       " << numStations << "\n";
    std::cout << "Load policy:          "
              << (perStationLoadFixed ? "fixed per-station" : "fixed per-AC")
              << "\n";
    std::cout << "RngSeed:              " << rngSeed << "\n";
    std::cout << "RngRun:               " << rngRun << "\n";

    std::cout << "\nAC assignment (stations / per-station Mbps / total AC Mbps):\n";

    for (int g = 0; g < 4; ++g)
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
        const int group = GroupForStation(i, nBe, nBk, nVi, nVo);

        const uint64_t rateBps = static_cast<uint64_t>(
            std::llround(perStationLoadMbps[group] * 1'000'000.0));

        OnOffHelper client("ns3::UdpSocketFactory", dest);

        client.SetConstantRate(DataRate(rateBps), payloadSize);

        client.SetAttribute("Tos", UintegerValue(kAcGroups[group].tos));

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

    std::array<GroupAggregate, 4> perGroup{};

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

    std::array<uint64_t, 4> macAttemptsPerGroup{};
    std::array<uint64_t, 4> macRetriesPerGroup{};

    for (uint32_t i = 0; i < numStations; ++i)
    {
        const int group = GroupForStation(i, nBe, nBk, nVi, nVo);

        const uint32_t nodeId = staNodes.Get(i)->GetId();

        macAttemptsPerGroup[group] += retryCounter.GetAttemptsForNode(nodeId);
        macRetriesPerGroup[group] += retryCounter.GetRetriesForNode(nodeId);
    }

    // ======================================================================
    // Output header
    // ======================================================================

    std::cout << std::fixed << std::setprecision(6);

    std::cout << "\n";
    std::cout << "=============================================\n";
    std::cout << "        EDCA RATIO RESULTS - FOUR ACs\n";
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
            << "nVo,"
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
            << "pcapEnabled\n";
    }

    // ======================================================================
    // Write one row for each AC
    // ======================================================================

    for (int g = 0; g < 4; ++g)
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

        std::cout << "\n--- " << kAcGroups[g].label << " (" << stationsPerAc[g]
                  << " STAs) ---\n";
        std::cout << "  Offered load (total): " << actualPerAcLoadMbps[g] << " Mbps\n";
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

        if (agg.rxPackets > agg.txPackets)
        {
            NS_LOG_WARN("RX packets exceed TX packets for " << kAcGroups[g].label);
        }

        if (macRetries > macAttempts)
        {
            NS_LOG_WARN("MAC retries exceed attempts for " << kAcGroups[g].label);
        }

        csv << "EDCA," << scenarioLabel << ',' << kAcGroups[g].label << ',' << numStations
            << ',' << nBe << ',' << nBk << ',' << nVi << ',' << nVo << ','
            << stationsPerAc[g] << ',' << bssRadius << ','
            << (perStationLoadFixed ? "perStation" : "perAc") << ','
            << perStationLoadMbps[g] << ',' << actualPerAcLoadMbps[g] << ','
            << payloadSize << ',' << 54 << ',' << 24 << ',' << simulationTime << ','
            << warmupTime << ',' << drainTime << ',' << rngSeed << ',' << rngRun << ','
            << throughputMbps << ',' << payloadGoodputMbps << ',' << pdr << ','
            << packetLossRate << ',' << meanDelayMs << ',' << meanJitterMs << ','
            << agg.jitterSamples << ',' << agg.txPackets << ',' << agg.rxPackets << ','
            << agg.txBytes << ',' << agg.rxBytes << ',' << agg.lostPackets << ','
            << macAttempts << ',' << macRetries << ',' << (enablePcap ? 1 : 0) << '\n';
    }

    csv.close();

    // ======================================================================
    // Finalize simulation
    // ======================================================================

    Simulator::Destroy();

    std::cout << "\nResults written to: " << outputCsv << "\n";

    return 0;
}
