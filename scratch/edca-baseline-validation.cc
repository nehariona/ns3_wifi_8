/*



 * EDCA baseline validation scenario for ns-3.48



 *



 * Purpose:



 *   Controlled single-BSS, uplink-only EDCA baseline with all four



 *   EDCA Access Categories active simultaneously:



 *



 *       AC_BE = Best Effort



 *       AC_BK = Background



 *       AC_VI = Video



 *       AC_VO = Voice



 *



 * Experimental configuration:



 *   - 1 AP + N stations in one infrastructure BSS



 *   - N should preferably be divisible by 4



 *   - STAs uniformly distributed over a disc around the AP



 *   - Equal aggregate offered load per AC



 *   - Fixed 802.11a PHY rate:



 *       54 Mbps data



 *       24 Mbps control



 *   - Friis propagation only



 *   - FlowMonitor for per-AC application TX/RX, PDR, delay, jitter, loss



 *   - MAC retransmissions counted from IEEE 802.11 Retry bit



 *   - Explicit mobility RNG stream



 *   - Optional PCAP capture



 *   - CSV output with one row per AC



 *



 * Default:



 *   12 STAs



 *   8 Mbps aggregate offered load



 *



 * AC assignment:



 *



 *   STA 0, 1, 2   -> AC_BE



 *   STA 3, 4, 5   -> AC_BK



 *   STA 6, 7, 8   -> AC_VI



 *   STA 9,10,11   -> AC_VO



 *



 * Therefore:



 *



 *   3 STAs/AC



 *   0.666667 Mbps/STA



 *   2 Mbps/AC



 *   8 Mbps total



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



NS_LOG_COMPONENT_DEFINE("EdcaBaselineValidation");



/*



 * --------------------------------------------------------------------------



 * Access Category definition



 * --------------------------------------------------------------------------



 *



 * These ToS values are selected to exercise the four intended QoS/EDCA



 * categories through ns-3's socket/application QoS classification path.



 *



 * Intended mapping:



 *



 *   0x70 -> UP 3 -> AC_BE



 *   0x28 -> UP 1 -> AC_BK



 *   0xb8 -> UP 5 -> AC_VI



 *   0xc0 -> UP 6 -> AC_VO



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



const std::array<AcGroup, 4> kAcGroups = {{



    {"AC_BE", 0x70},



    {"AC_BK", 0x28},



    {"AC_VI", 0xb8},



    {"AC_VO", 0xc0},



}};



/*



 * --------------------------------------------------------------------------



 * Station -> AC mapping



 * --------------------------------------------------------------------------



 *



 * For 12 STAs:



 *



 *   0,1,2     -> BE



 *   3,4,5     -> BK



 *   6,7,8     -> VI



 *   9,10,11   -> VO



 *



 * We require numStations to be divisible by 4 so that every AC receives



 * exactly the same number of stations.



 */



int



GroupForStation(uint32_t staIndex, uint32_t numStations)



{



    if (numStations % 4 != 0)



    {



        NS_FATAL_ERROR(



            "numStations must be divisible by 4 for equal four-AC grouping. "



            "Use 4, 8, 12, 16, ...");



    }



    const uint32_t stationsPerAc = numStations / 4;



    if (staIndex < stationsPerAc)



    {



        return 0; // AC_BE



    }



    if (staIndex < 2 * stationsPerAc)



    {



        return 1; // AC_BK



    }



    if (staIndex < 3 * stationsPerAc)



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



 *   1. DATA MPDU transmissions observed at PhyTxBegin



 *   2. DATA MPDU transmissions carrying the IEEE 802.11 Retry bit



 *



 * The counter is maintained per STA so that we can later aggregate



 * attempts/retries according to the STA's AC group.



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



    uint64_t GetRetriesForGroup(



        const NodeContainer& staNodes,



        uint32_t numStations) const;



    uint64_t GetAttemptsForGroup(



        const NodeContainer& staNodes,



        uint32_t numStations) const;



  private:



    std::map<uint32_t, uint64_t> m_retriesPerNode;



    std::map<uint32_t, uint64_t> m_attemptsPerNode;



};



void



MacRetryCounter::Connect(NodeContainer staNodes)



{



    /*



     * Initialize counters for every STA.



     */



    for (uint32_t i = 0; i < staNodes.GetN(); ++i)



    {



        const uint32_t nodeId = staNodes.Get(i)->GetId();



        m_retriesPerNode[nodeId] = 0;



        m_attemptsPerNode[nodeId] = 0;



    }



    /*



     * Listen to PHY DATA transmissions from all Wi-Fi devices.



     */



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



    /*



     * Peek at the Wi-Fi MAC header.



     */



    WifiMacHeader hdr;



    Ptr<Packet> copy = packet->Copy();



    if (copy->PeekHeader(hdr) == 0)



    {



        return;



    }



    /*



     * Only DATA frames are counted.



     */



    if (!hdr.IsData())



    {



        return;



    }



    /*



     * Extract NodeId from the trace context.



     *



     * Example:



     *



     * /NodeList/3/DeviceList/0/$ns3::WifiNetDevice/...



     */



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



    /*



     * If this NodeId is not in the STA map, it is the AP or another node.



     *



     * We intentionally ignore AP transmissions because this is an



     * uplink-only experiment.



     */



    auto attemptIt = m_attemptsPerNode.find(nodeId);



    if (attemptIt == m_attemptsPerNode.end())



    {



        return;



    }



    /*



     * Count this DATA MPDU transmission attempt.



     */



    ++attemptIt->second;



    /*



     * If Retry bit is set, this is a retransmission of the MAC frame.



     */



    if (hdr.IsRetry())



    {



        ++m_retriesPerNode[nodeId];



    }



}



uint64_t



MacRetryCounter::GetRetriesForNode(uint32_t nodeId) const



{



    auto it = m_retriesPerNode.find(nodeId);



    if (it == m_retriesPerNode.end())



    {



        return 0;



    }



    return it->second;



}



uint64_t



MacRetryCounter::GetAttemptsForNode(uint32_t nodeId) const



{



    auto it = m_attemptsPerNode.find(nodeId);



    if (it == m_attemptsPerNode.end())



    {



        return 0;



    }



    return it->second;



}



uint64_t



MacRetryCounter::GetRetriesForGroup(



    const NodeContainer& staNodes,



    uint32_t numStations) const



{



    std::array<uint64_t, 4> groupRetries{};



    for (uint32_t i = 0; i < staNodes.GetN(); ++i)



    {



        const int group = GroupForStation(i, numStations);



        const uint32_t nodeId = staNodes.Get(i)->GetId();



        groupRetries[group] += GetRetriesForNode(nodeId);



    }



    /*



     * This function is retained for completeness.



     * The main() function below calculates all four values explicitly.



     */



    uint64_t total = 0;



    for (const auto value : groupRetries)



    {



        total += value;



    }



    return total;



}



uint64_t



MacRetryCounter::GetAttemptsForGroup(



    const NodeContainer& staNodes,



    uint32_t numStations) const



{



    std::array<uint64_t, 4> groupAttempts{};



    for (uint32_t i = 0; i < staNodes.GetN(); ++i)



    {



        const int group = GroupForStation(i, numStations);



        const uint32_t nodeId = staNodes.Get(i)->GetId();



        groupAttempts[group] += GetAttemptsForNode(nodeId);



    }



    uint64_t total = 0;



    for (const auto value : groupAttempts)



    {



        total += value;



    }



    return total;



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



    uint32_t numStations = 12;



    uint32_t payloadSize = 1024;



    /*



     * Aggregate application offered load.



     *



     * With 12 STAs:



     *



     *   8 Mbps / 12 = 0.666667 Mbps per STA



     *



     * 3 STAs per AC:



     *



     *   3 * 0.666667 = 2 Mbps per AC



     */



    double offeredLoadMbps = 8.0;



    /*



     * Traffic measurement interval.



     */



    double simulationTime = 60.0;



    /*



     * Warm-up before traffic starts.



     */



    double warmupTime = 5.0;



    /*



     * Time allowed after traffic stops for queued packets to drain.



     */



    double drainTime = 5.0;



    /*



     * STA placement radius.



     */



    double bssRadius = 5.0;



    /*



     * RngSeed and RngRun.



     *



     * Per the ns-3 manual, independent statistical replications should



     * be produced by holding the Seed fixed and varying the Run number.



     * rngSeed is still exposed on the command line for flexibility, but



     * the default sweep should only vary rngRun.



     */



    uint32_t rngSeed = 1;



    uint32_t rngRun = 1;



    /*



     * Optional PCAP.



     */



    bool enablePcap = false;



    /*



     * CSV output.



     */



    std::string outputCsv = "results/edca_baseline_4ac.csv";



    /*



     * PCAP directory.



     */



    std::string pcapDirectory = "results/pcap";



    // ======================================================================



    // Command line



    // ======================================================================



    CommandLine cmd(__FILE__);



    cmd.AddValue(



        "numStations",



        "Number of stations; must be divisible by 4",



        numStations);



    cmd.AddValue(



        "payloadSize",



        "UDP payload size in bytes",



        payloadSize);



    cmd.AddValue(



        "offeredLoadMbps",



        "Aggregate uplink offered load in Mbit/s",



        offeredLoadMbps);



    cmd.AddValue(



        "simulationTime",



        "Measurement window in seconds",



        simulationTime);



    cmd.AddValue(



        "warmupTime",



        "Traffic warm-up time in seconds",



        warmupTime);



    cmd.AddValue(



        "drainTime",



        "Post-traffic drain time in seconds",



        drainTime);



    cmd.AddValue(



        "bssRadius",



        "STA placement disc radius in metres",



        bssRadius);



    cmd.AddValue(



        "rngSeed",



        "RngSeed value",



        rngSeed);



    cmd.AddValue(



        "rngRun",



        "RngRun index",



        rngRun);



    cmd.AddValue(



        "enablePcap",



        "Enable PCAP capture",



        enablePcap);



    cmd.AddValue(



        "outputCsv",



        "CSV output file",



        outputCsv);



    cmd.AddValue(



        "pcapDirectory",



        "PCAP output directory",



        pcapDirectory);



    cmd.Parse(argc, argv);



    // ======================================================================



    // Validation



    // ======================================================================



    if (numStations == 0)



    {



        NS_FATAL_ERROR("numStations must be > 0");



    }



    if (numStations % 4 != 0)



    {



        NS_FATAL_ERROR(



            "numStations must be divisible by 4. "



            "Use 4, 8, 12, 16, ...");



    }



    if (payloadSize == 0)



    {



        NS_FATAL_ERROR("payloadSize must be > 0");



    }



    if (offeredLoadMbps <= 0.0)



    {



        NS_FATAL_ERROR("offeredLoadMbps must be > 0");



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



    // ======================================================================



    // Randomness



    // ======================================================================



    /*



     * Same seed and RngRun should be used for corresponding EDCA/P-EDCA



     * experiments.



     */



    RngSeedManager::SetSeed(rngSeed);



    RngSeedManager::SetRun(rngRun);



    const double trafficStart = warmupTime;



    const double trafficStop =



        trafficStart + simulationTime;



    const double simulationStop =



        trafficStop + drainTime;



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



    /*



     * Explicit Friis propagation model.



     *



     * Do NOT use:



     *



     *   YansWifiChannelHelper::Default()



     *



     * followed by another propagation-loss model.



     *



     * This experiment intentionally uses one propagation-loss model.



     */



    YansWifiChannelHelper channel;



    channel.SetPropagationDelay(



        "ns3::ConstantSpeedPropagationDelayModel");



    channel.AddPropagationLoss(



        "ns3::FriisPropagationLossModel",



        "Frequency",



        DoubleValue(5.18e9));



    YansWifiPhyHelper phy;



    phy.SetChannel(channel.Create());



    phy.SetPcapDataLinkType(



        WifiPhyHelper::DLT_IEEE802_11_RADIO);



    /*



     * Channel 36:



     *



     *   5 GHz



     *   20 MHz



     */



    phy.Set(



        "ChannelSettings",



        StringValue("{36, 20, BAND_5GHZ, 0}"));



    // ======================================================================



    // Wi-Fi configuration



    // ======================================================================



    WifiHelper wifi;



    /*



     * 802.11a PHY.



     */



    wifi.SetStandard(WIFI_STANDARD_80211a);



    /*



     * Fixed-rate PHY.



     */



    wifi.SetRemoteStationManager(



        "ns3::ConstantRateWifiManager",



        "DataMode",



        StringValue("OfdmRate54Mbps"),



        "ControlMode",



        StringValue("OfdmRate24Mbps"));



    WifiMacHelper mac;



    const Ssid ssid("edca-baseline-4ac");



    // ======================================================================



    // STA MAC



    // ======================================================================



    mac.SetType(



        "ns3::StaWifiMac",



        "QosSupported",



        BooleanValue(true),



        "Ssid",



        SsidValue(ssid),



        "ActiveProbing",



        BooleanValue(false));



    NetDeviceContainer staDevices =



        wifi.Install(phy, mac, staNodes);



    // ======================================================================



    // AP MAC



    // ======================================================================



    mac.SetType(



        "ns3::ApWifiMac",



        "QosSupported",



        BooleanValue(true),



        "Ssid",



        SsidValue(ssid),



        "EnableBeaconJitter",



        BooleanValue(false));



    NetDeviceContainer apDevice =



        wifi.Install(phy, mac, apNode);



    // ======================================================================



    // Mobility



    // ======================================================================



    /*



     * AP at origin.



     */



    MobilityHelper apMobility;



    Ptr<ListPositionAllocator> apPosition =



        CreateObject<ListPositionAllocator>();



    apPosition->Add(



        Vector(0.0, 0.0, 0.0));



    apMobility.SetPositionAllocator(apPosition);



    apMobility.SetMobilityModel(



        "ns3::ConstantPositionMobilityModel");



    apMobility.Install(apNode);



    /*



     * STAs uniformly distributed over a disc.



     */



    MobilityHelper staMobility;



    Ptr<UniformDiscPositionAllocator> staAllocator =



        CreateObject<UniformDiscPositionAllocator>();



    staAllocator->SetX(0.0);



    staAllocator->SetY(0.0);



    staAllocator->SetZ(0.0);



    staAllocator->SetRho(bssRadius);



    /*



     * Explicit RNG stream for reproducible placement.



     *



     * This must be assigned before Install(), because the positions are



     * generated during installation.



     */



    staAllocator->AssignStreams(1000);



    staMobility.SetPositionAllocator(staAllocator);



    staMobility.SetMobilityModel(



        "ns3::ConstantPositionMobilityModel");



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



    address.SetBase(



        "192.168.1.0",



        "255.255.255.0");



    Ipv4InterfaceContainer apInterface =



        address.Assign(apDevice);



    Ipv4InterfaceContainer staInterfaces =



        address.Assign(staDevices);



    // ======================================================================



    // Create STA -> AC mappings



    // ======================================================================



    /*



     * nodeId -> AC group



     *



     * group:



     *



     *   0 = BE



     *   1 = BK



     *   2 = VI



     *   3 = VO



     */



    std::map<uint32_t, int> nodeIdToGroup;



    /*



     * source IPv4 address -> AC group



     */



    std::map<Ipv4Address, int> addressToGroup;



    for (uint32_t i = 0; i < numStations; ++i)



    {



        const int group =



            GroupForStation(i, numStations);



        const uint32_t nodeId =



            staNodes.Get(i)->GetId();



        const Ipv4Address sourceAddress =



            staInterfaces.GetAddress(i);



        nodeIdToGroup[nodeId] = group;



        addressToGroup[sourceAddress] = group;



    }



    // ======================================================================



    // Print AC configuration



    // ======================================================================



    const uint32_t stationsPerAc =



        numStations / 4;



    const double perStationLoadMbps =



        offeredLoadMbps /



        static_cast<double>(numStations);



    const double perAcLoadMbps =



        perStationLoadMbps *



        static_cast<double>(stationsPerAc);



    std::cout << "\n";



    std::cout << "=============================================\n";



    std::cout << "       FOUR-AC EDCA BASELINE\n";



    std::cout << "=============================================\n";



    std::cout << "Total stations:       "



              << numStations << "\n";



    std::cout << "Stations per AC:      "



              << stationsPerAc << "\n";



    std::cout << "Aggregate load:       "



              << offeredLoadMbps << " Mbps\n";



    std::cout << "Load per STA:         "



              << perStationLoadMbps << " Mbps\n";



    std::cout << "Load per AC:          "



              << perAcLoadMbps << " Mbps\n";



    std::cout << "RngSeed:              "



              << rngSeed << "\n";



    std::cout << "RngRun:               "



              << rngRun << "\n";



    std::cout << "\nAC assignment:\n";



    for (int g = 0; g < 4; ++g)



    {



        std::cout



            << "  "



            << kAcGroups[g].label



            << " : ";



        for (uint32_t i = 0; i < numStations; ++i)



        {



            if (GroupForStation(i, numStations) == g)



            {



                std::cout << i << " ";



            }



        }



        std::cout << "\n";



    }



    std::cout << "=============================================\n\n";



    // ======================================================================



    // UDP server



    // ======================================================================



    const uint16_t port = 5000;



    UdpServerHelper server(port);



    ApplicationContainer serverApp =



        server.Install(apNode.Get(0));



    serverApp.Start(Seconds(0.0));



    serverApp.Stop(



        Seconds(simulationStop));



    // ======================================================================



    // UDP traffic



    // ======================================================================



    /*



     * Each STA gets an equal share of the aggregate offered load.



     */



    const uint64_t perStationRateBps =



        static_cast<uint64_t>(



            std::llround(



                perStationLoadMbps *



                1'000'000.0));



    const InetSocketAddress dest(



        apInterface.GetAddress(0),



        port);



    for (uint32_t i = 0;



         i < numStations;



         ++i)



    {



        /*



         * Determine this station's AC.



         */



        const int group =



            GroupForStation(i, numStations);



        /*



         * Create UDP OnOff application.



         */



        OnOffHelper client(



            "ns3::UdpSocketFactory",



            dest);



        /*



         * Constant-rate CBR traffic.



         */



        client.SetConstantRate(



            DataRate(perStationRateBps),



            payloadSize);



        /*



         * Assign this application's traffic to its AC.



         *



         * The four ToS values correspond to the intended QoS priorities.



         */



        client.SetAttribute(



            "Tos",



            UintegerValue(



                kAcGroups[group].tos));



        /*



         * Install on STA.



         */



        ApplicationContainer app =



            client.Install(



                staNodes.Get(i));



        /*



         * All traffic starts and stops at the same time.



         */



        app.Start(



            Seconds(trafficStart));



        app.Stop(



            Seconds(trafficStop));



    }



    // ======================================================================



    // PCAP



    // ======================================================================



    if (enablePcap)



    {



        std::filesystem::create_directories(



            pcapDirectory);



        const std::string prefix =



            pcapDirectory +



            "/edca-4ac-n" +



            std::to_string(numStations) +



            "-run" +



            std::to_string(rngRun);



        /*



         * AP capture.



         */



        phy.EnablePcap(



            prefix + "-ap",



            apDevice.Get(0));



        /*



         * Individual STA captures.



         */



        for (uint32_t i = 0;



             i < staDevices.GetN();



             ++i)



        {



            phy.EnablePcap(



                prefix +



                    "-sta" +



                    std::to_string(i),



                staDevices.Get(i));



        }



    }



    // ======================================================================



    // FlowMonitor



    // ======================================================================



    FlowMonitorHelper flowmonHelper;



    Ptr<FlowMonitor> monitor =



        flowmonHelper.InstallAll();



    /*



     * FlowMonitor starts at time 0.



     *



     * There is no UDP traffic before trafficStart.



     */



    monitor->SetAttribute(



        "StartTime",



        TimeValue(Seconds(0.0)));



    /*



     * Allow packets to remain unresolved for at most the drain interval.



     */



    monitor->SetAttribute(



        "MaxPerHopDelay",



        TimeValue(Seconds(drainTime)));



    // ======================================================================



    // MAC retry counter



    // ======================================================================



    MacRetryCounter retryCounter;



    retryCounter.Connect(staNodes);



    // ======================================================================



    // Simulation



    // ======================================================================



    Simulator::Stop(



        Seconds(simulationStop));



    Simulator::Run();



    // ======================================================================



    // FlowMonitor finalization



    // ======================================================================



    monitor->CheckForLostPackets(



        Seconds(drainTime));



    Ptr<Ipv4FlowClassifier> classifier =



        DynamicCast<Ipv4FlowClassifier>(



            flowmonHelper.GetClassifier());



    const FlowMonitor::FlowStatsContainer stats =



        monitor->GetFlowStats();



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



    std::array<GroupAggregate, 4>



        perGroup{};



    // ======================================================================



    // Aggregate FlowMonitor data by AC



    // ======================================================================



    for (const auto& flow : stats)



    {



        const FlowId flowId =



            flow.first;



        const auto tuple =



            classifier->FindFlow(flowId);



        /*



         * UDP = protocol 17.



         *



         * Keep only STA -> AP traffic.



         */



        if (tuple.protocol != 17 ||



            tuple.destinationAddress !=



                apInterface.GetAddress(0))



        {



            continue;



        }



        /*



         * Identify the AC from the source STA address.



         */



        auto groupIt =



            addressToGroup.find(



                tuple.sourceAddress);



        if (groupIt ==



            addressToGroup.end())



        {



            continue;



        }



        const int group =



            groupIt->second;



        GroupAggregate& agg =



            perGroup[group];



        const auto& s =



            flow.second;



        agg.txPackets +=



            s.txPackets;



        agg.rxPackets +=



            s.rxPackets;



        agg.txBytes +=



            s.txBytes;



        agg.rxBytes +=



            s.rxBytes;



        agg.lostPackets +=



            s.lostPackets;



        agg.delaySum +=



            s.delaySum.GetSeconds();



        agg.jitterSum +=



            s.jitterSum.GetSeconds();



        /*



         * FlowMonitor jitter:



         *



         * R received packets -> R-1 jitter samples.



         */



        if (s.rxPackets > 1)



        {



            agg.jitterSamples +=



                static_cast<uint64_t>(



                    s.rxPackets - 1);



        }



    }



    // ======================================================================



    // Calculate per-AC MAC attempts/retries



    // ======================================================================



    std::array<uint64_t, 4>



        macAttemptsPerGroup{};



    std::array<uint64_t, 4>



        macRetriesPerGroup{};



    for (uint32_t i = 0;



         i < numStations;



         ++i)



    {



        const int group =



            GroupForStation(i, numStations);



        const uint32_t nodeId =



            staNodes.Get(i)->GetId();



        macAttemptsPerGroup[group] +=



            retryCounter.GetAttemptsForNode(



                nodeId);



        macRetriesPerGroup[group] +=



            retryCounter.GetRetriesForNode(



                nodeId);



    }



    // ======================================================================



    // Output header



    // ======================================================================



    std::cout << std::fixed



              << std::setprecision(6);



    std::cout << "\n";



    std::cout << "=============================================\n";



    std::cout << "          EDCA RESULTS - FOUR ACs\n";



    std::cout << "=============================================\n";



    // ======================================================================



    // CSV directory



    // ======================================================================



    const std::filesystem::path csvPath(



        outputCsv);



    if (!csvPath.parent_path().empty())



    {



        std::filesystem::create_directories(



            csvPath.parent_path());



    }



    const bool fileExists =



        std::filesystem::exists(csvPath) &&



        std::filesystem::file_size(csvPath) > 0;



    std::ofstream csv(



        outputCsv,



        std::ios::app);



    if (!csv)



    {



        NS_FATAL_ERROR(



            "Could not open CSV output file: "



            << outputCsv);



    }



    // ======================================================================



    // CSV header



    // ======================================================================



    if (!fileExists)



    {



        csv



            << "protocol,"



            << "ac,"



            << "numStations,"



            << "stationsPerAc,"



            << "bssRadius,"



            << "offeredLoadMbps,"



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



    for (int g = 0;



         g < 4;



         ++g)



    {



        const GroupAggregate& agg =



            perGroup[g];



        // --------------------------------------------------------------



        // IP throughput



        // --------------------------------------------------------------



        const double throughputMbps =



            (static_cast<double>(



                 agg.rxBytes) *



             8.0) /



            (simulationTime *



             1'000'000.0);



        // --------------------------------------------------------------



        // Payload goodput



        // --------------------------------------------------------------



        const double payloadGoodputMbps =



            (static_cast<double>(



                 agg.rxPackets) *



             static_cast<double>(



                 payloadSize) *



             8.0) /



            (simulationTime *



             1'000'000.0);



        // --------------------------------------------------------------



        // PDR



        // --------------------------------------------------------------



        const double pdr =



            agg.txPackets > 0



                ? static_cast<double>(



                      agg.rxPackets) /



                      static_cast<double>(



                          agg.txPackets)



                : 0.0;



        // --------------------------------------------------------------



        // Packet loss



        // --------------------------------------------------------------



        const double packetLossRate =



            agg.txPackets > 0



                ? 1.0 - pdr



                : 0.0;



        // --------------------------------------------------------------



        // Mean delay



        // --------------------------------------------------------------



        const double meanDelayMs =



            agg.rxPackets > 0



                ? (agg.delaySum /



                   static_cast<double>(



                       agg.rxPackets)) *



                      1000.0



                : std::numeric_limits<double>::quiet_NaN();



        // --------------------------------------------------------------



        // Mean jitter



        // --------------------------------------------------------------



        const double meanJitterMs =



            agg.jitterSamples > 0



                ? (agg.jitterSum /



                   static_cast<double>(



                       agg.jitterSamples)) *



                      1000.0



                : std::numeric_limits<double>::quiet_NaN();



        // --------------------------------------------------------------



        // MAC statistics



        // --------------------------------------------------------------



        const uint64_t macAttempts =



            macAttemptsPerGroup[g];



        const uint64_t macRetries =



            macRetriesPerGroup[g];



        // --------------------------------------------------------------



        // Console output



        // --------------------------------------------------------------



        std::cout



            << "\n--- "



            << kAcGroups[g].label



            << " ---\n";



        std::cout



            << "  Stations:             "



            << stationsPerAc



            << "\n";



        std::cout



            << "  Offered load:         "



            << perAcLoadMbps



            << " Mbps\n";



        std::cout



            << "  TX packets:           "



            << agg.txPackets



            << "\n";



        std::cout



            << "  RX packets:           "



            << agg.rxPackets



            << "\n";



        std::cout



            << "  IP throughput:        "



            << throughputMbps



            << " Mbps\n";



        std::cout



            << "  Payload goodput:      "



            << payloadGoodputMbps



            << " Mbps\n";



        std::cout



            << "  PDR:                  "



            << pdr * 100.0



            << " %\n";



        std::cout



            << "  Packet loss rate:     "



            << packetLossRate * 100.0



            << " %\n";



        std::cout



            << "  Mean delay:           "



            << meanDelayMs



            << " ms\n";



        std::cout



            << "  Mean jitter:          "



            << meanJitterMs



            << " ms\n";



        std::cout



            << "  Jitter samples:       "



            << agg.jitterSamples



            << "\n";



        std::cout



            << "  FlowMonitor lost:     "



            << agg.lostPackets



            << "\n";



        std::cout



            << "  MAC data attempts:    "



            << macAttempts



            << "\n";



        std::cout



            << "  MAC retransmissions:  "



            << macRetries



            << "\n";



        // --------------------------------------------------------------



        // Sanity checks



        // --------------------------------------------------------------



        if (agg.rxPackets >



            agg.txPackets)



        {



            NS_LOG_WARN(



                "RX packets exceed TX packets for "



                << kAcGroups[g].label);



        }



        if (macRetries >



            macAttempts)



        {



            NS_LOG_WARN(



                "MAC retries exceed attempts for "



                << kAcGroups[g].label);



        }



        // --------------------------------------------------------------



        // CSV row



        // --------------------------------------------------------------



        csv



            << "EDCA,"



            << kAcGroups[g].label << ','



            << numStations << ','



            << stationsPerAc << ','



            << bssRadius << ','



            << offeredLoadMbps << ','



            << perStationLoadMbps << ','



            << perAcLoadMbps << ','



            << payloadSize << ','



            << 54 << ','



            << 24 << ','



            << simulationTime << ','



            << warmupTime << ','



            << drainTime << ','



            << rngSeed << ','



            << rngRun << ','



            << throughputMbps << ','



            << payloadGoodputMbps << ','



            << pdr << ','



            << packetLossRate << ','



            << meanDelayMs << ','



            << meanJitterMs << ','



            << agg.jitterSamples << ','



            << agg.txPackets << ','



            << agg.rxPackets << ','



            << agg.txBytes << ','



            << agg.rxBytes << ','



            << agg.lostPackets << ','



            << macAttempts << ','



            << macRetries << ','



            << (enablePcap ? 1 : 0)



            << '\n';



    }



    csv.close();



    // ======================================================================



    // Finalize simulation



    // ======================================================================



    Simulator::Destroy();



    std::cout



        << "\nResults written to: "



        << outputCsv



        << "\n";



    return 0;



}
