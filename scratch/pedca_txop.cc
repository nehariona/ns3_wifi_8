// Smoke test for the P-EDCA patch: AP + P-EDCA STAs sending AC_VO uplink + legacy STAs
// saturating AC_BE uplink. Counts DS-CTS / RTS frames and AC_VO delivery delay.

#include "ns3/boolean.h"
#include "ns3/command-line.h"
#include "ns3/config.h"
#include "ns3/double.h"
#include "ns3/rng-seed-manager.h"
#include "ns3/mobility-helper.h"
#include "ns3/packet.h"
#include "ns3/qos-txop.h"
#include "ns3/simulator.h"
#include "ns3/socket.h"
#include "ns3/ssid.h"
#include "ns3/string.h"
#include "ns3/uinteger.h"
#include "ns3/wifi-mac.h"
#include "ns3/wifi-net-device.h"
#include "ns3/wifi-phy.h"
#include "ns3/wifi-psdu.h"
#include "ns3/yans-wifi-helper.h"

#include <algorithm>
#include <iostream>
#include <map>
#include <set>
#include <vector>

using namespace ns3;

namespace
{
const Mac48Address kDsCts("00:0F:AC:47:43:00");
uint32_t g_dsCts = 0;
uint32_t g_rtsPedca = 0;
uint32_t g_rtsOther = 0;
std::map<uint64_t, Time> g_sent;
std::vector<double> g_voDelaysUs;
uint64_t g_voRx = 0, g_beRx = 0, g_voTx = 0;
std::set<Mac48Address> g_pedcaAddrs;
Time g_windowEnd{0};
Time g_dsStart{0};
Time g_dsEnd{0};
bool g_dsMixed = false;
uint32_t g_dsMulti = 0;
Time g_lastOtherTx{-1};
std::map<std::string, uint32_t> g_cls;
Time g_dbgStart{0};
Time g_dbgEnd{0};
uint32_t g_legacyInWindow = 0, g_rtsInWindow = 0, g_ctsToPedca = 0, g_dsCtsInWindow = 0;
std::map<int64_t, uint32_t> g_rtsOffsetUs;

void
PhyTx(WifiConstPsduMap psduMap, WifiTxVector txVector, double)
{
    for (const auto& [id, psdu] : psduMap)
    {
        const auto& hdr = psdu->GetHeader(0);
        const auto now = Simulator::Now();
        if (!(hdr.IsCts() && hdr.GetAddr1() == kDsCts))
        {
            g_lastOtherTx = now;
        }
        const bool inWindow = now > g_dsStart + MicroSeconds(1) && now < g_windowEnd;
        if (now >= g_dsStart && now <= g_dsEnd && !(hdr.IsCts() && hdr.GetAddr1() == kDsCts))
        {
            g_dsMixed = true; // another frame overlaps the DS-CTS
        }
        const bool fromPedca = g_pedcaAddrs.contains(hdr.GetAddr2());
        if (now >= g_dbgStart && now <= g_dbgEnd)
        {
            std::cout << "DBG " << now.As(Time::US) << " " << hdr.GetTypeString() << " TA="
                      << hdr.GetAddr2() << " RA=" << hdr.GetAddr1() << " dur=" << hdr.GetDuration().As(Time::US)
                      << " txdur=" << WifiPhy::CalculateTxDuration(psdu->GetSize(), txVector, WIFI_PHY_BAND_5GHZ).As(Time::US)
                      << " nMpdu=" << psdu->GetNMpdus() << std::endl;
        }
        if (inWindow && !(hdr.IsCts() && hdr.GetAddr1() == kDsCts))
        {
            if (hdr.IsCts() && g_pedcaAddrs.contains(hdr.GetAddr1()))
            {
                // CTS in response to a Stage-2 RTS
            }
            else if (hdr.IsRts() && fromPedca)
            {
                ++g_rtsInWindow;
                const auto dsEnd = g_windowEnd - MicroSeconds(97);
                g_rtsOffsetUs[(now - dsEnd).GetMicroSeconds()]++;
            }
            else
            {
                ++g_legacyInWindow;
                std::string cls;
                if (hdr.IsAck() || hdr.IsBlockAck() || hdr.IsCts())
                {
                    cls = "SIFS response (Ack/BlockAck/CTS)";
                }
                else if (g_dsMixed)
                {
                    cls = "DS-CTS overlapped by a data/control frame (not decodable)";
                }
                else if (g_dsMulti > 1)
                {
                    cls = "only simultaneous DS-CTS frames (should have combined)";
                }
                else if (now <= g_dsStart + MicroSeconds(5))
                {
                    cls = "started before DS-CTS detectable (<5us)";
                }
                else
                {
                    cls = "UNEXPLAINED";
                    std::cout << "UNEXPL " << now.As(Time::US) << " offset="
                              << (now - g_dsStart).As(Time::US) << " " << hdr.GetTypeString()
                              << " from " << hdr.GetAddr2() << std::endl;
                }
                g_cls[cls]++;
                std::cout << now.As(Time::US) << " non-P-EDCA TX in window: "
                          << hdr.GetTypeString() << " from " << hdr.GetAddr2() << std::endl;
            }
        }
        if (hdr.IsCts() && g_pedcaAddrs.contains(hdr.GetAddr1()))
        {
            ++g_ctsToPedca;
        }
        if (hdr.IsCts() && hdr.GetAddr1() == kDsCts)
        {
            if (inWindow)
            {
                ++g_dsCtsInWindow;
            }
            ++g_dsCts;
            if (now <= g_dsStart + MicroSeconds(1))
            {
                ++g_dsMulti; // another DS-CTS in the same slot: same window
                continue;
            }
            g_dsMulti = 1;
            g_dsMixed = (now <= g_lastOtherTx + MicroSeconds(1));
            g_dsStart = now;
            g_dsEnd = now + WifiPhy::CalculateTxDuration(psdu->GetSize(), txVector, WIFI_PHY_BAND_5GHZ);
            g_windowEnd = now +
                          WifiPhy::CalculateTxDuration(psdu->GetSize(), txVector, WIFI_PHY_BAND_5GHZ) +
                          hdr.GetDuration();
            NS_ABORT_MSG_IF(hdr.GetDuration() != MicroSeconds(97),
                            "unexpected DS-CTS Duration " << hdr.GetDuration());
            NS_ABORT_MSG_IF(txVector.GetMode().GetDataRate(txVector) != 6000000,
                            "DS-CTS not at 6 Mb/s");
        }
        else if (hdr.IsRts())
        {
            (g_pedcaAddrs.contains(hdr.GetAddr2()) ? g_rtsPedca : g_rtsOther)++;
        }
    }
}

void
MacRx(Ptr<const Packet> p)
{
    if (auto it = g_sent.find(p->GetUid()); it != g_sent.end())
    {
        ++g_voRx;
        g_voDelaysUs.push_back((Simulator::Now() - it->second).GetMicroSeconds());
        g_sent.erase(it);
    }
    else
    {
        ++g_beRx;
    }
}

void
Send(Ptr<WifiNetDevice> dev, Mac48Address to, uint32_t size, uint8_t prio, Time interval)
{
    auto p = Create<Packet>(size);
    SocketPriorityTag tag;
    tag.SetPriority(prio);
    p->AddPacketTag(tag);
    if (prio == 6)
    {
        g_sent[p->GetUid()] = Simulator::Now();
        ++g_voTx;
    }
    dev->Send(p, to, 0x0800);
    Simulator::Schedule(interval, &Send, dev, to, size, prio, interval);
}
} // namespace

int
main(int argc, char* argv[])
{
    bool pedca = true;
    uint32_t nVo = 4;
    uint32_t nBe = 6;
    double simTime = 5;
    uint32_t seed = 1;
    CommandLine cmd(__FILE__);
    cmd.AddValue("pedca", "enable P-EDCA on AP and VO STAs", pedca);
    cmd.AddValue("nVo", "number of AC_VO STAs", nVo);
    cmd.AddValue("nBe", "number of legacy AC_BE STAs", nBe);
    cmd.AddValue("simTime", "simulation time (s)", simTime);
    cmd.AddValue("seed", "RNG run", seed);
    double dbgStart = 0;
    double dbgEnd = 0;
    cmd.AddValue("dbgStart", "debug print start (s)", dbgStart);
    cmd.AddValue("dbgEnd", "debug print end (s)", dbgEnd);
    cmd.Parse(argc, argv);
    g_dbgStart = Seconds(dbgStart);
    g_dbgEnd = Seconds(dbgEnd);
    RngSeedManager::SetRun(seed);

    NodeContainer ap(1), vo(nVo), be(nBe);

    WifiHelper wifi;
    wifi.SetStandard(WIFI_STANDARD_80211ax);
    wifi.SetRemoteStationManager("ns3::ConstantRateWifiManager",
                                 "DataMode",
                                 StringValue("HeMcs5"),
                                 "ControlMode",
                                 StringValue("OfdmRate24Mbps"));
    YansWifiChannelHelper channel = YansWifiChannelHelper::Default();
    YansWifiPhyHelper phy;
    phy.SetChannel(channel.Create());
    phy.Set("ChannelSettings", StringValue("{36, 20, BAND_5GHZ, 0}"));

    Ssid ssid("pedca");
    WifiMacHelper mac;
    mac.SetType("ns3::ApWifiMac", "Ssid", SsidValue(ssid), "PEdcaSupported", BooleanValue(pedca));
    auto apDev = wifi.Install(phy, mac, ap);
    mac.SetType("ns3::StaWifiMac", "Ssid", SsidValue(ssid), "PEdcaSupported", BooleanValue(pedca));
    auto voDev = wifi.Install(phy, mac, vo);
    mac.SetType("ns3::StaWifiMac", "Ssid", SsidValue(ssid), "PEdcaSupported", BooleanValue(false));
    auto beDev = wifi.Install(phy, mac, be);

    MobilityHelper mobility;
    mobility.SetPositionAllocator("ns3::GridPositionAllocator",
                                  "DeltaX",
                                  DoubleValue(1.0),
                                  "GridWidth",
                                  UintegerValue(4));
    mobility.Install(ap);
    mobility.Install(vo);
    mobility.Install(be);

    auto apWifi = DynamicCast<WifiNetDevice>(apDev.Get(0));
    auto apAddr = apWifi->GetMac()->GetAddress();
    apWifi->GetMac()->TraceConnectWithoutContext("MacRx", MakeCallback(&MacRx));
    if (pedca)
    {
        g_pedcaAddrs.insert(apAddr); // an eligible AP also joins the P-EDCA contention
    }

    NetDeviceContainer all(apDev, voDev);
    all.Add(beDev);
    for (uint32_t i = 0; i < all.GetN(); ++i)
    {
        DynamicCast<WifiNetDevice>(all.Get(i))
            ->GetPhy()
            ->TraceConnectWithoutContext("PhyTxPsduBegin", MakeCallback(&PhyTx));
    }
    for (uint32_t i = 0; i < voDev.GetN(); ++i)
    {
        auto dev = DynamicCast<WifiNetDevice>(voDev.Get(i));
        g_pedcaAddrs.insert(dev->GetMac()->GetAddress());
        Simulator::Schedule(Seconds(1) + MicroSeconds(137 * i),
                            &Send,
                            dev,
                            apAddr,
                            200,
                            6,
                            MilliSeconds(5));
    }
    for (uint32_t i = 0; i < beDev.GetN(); ++i)
    {
        auto dev = DynamicCast<WifiNetDevice>(beDev.Get(i));
        Simulator::Schedule(Seconds(1) + MicroSeconds(53 * i),
                            &Send,
                            dev,
                            apAddr,
                            1400,
                            0,
                            MicroSeconds(500));
    }

    Simulator::Stop(Seconds(1 + simTime));
    Simulator::Run();

    std::sort(g_voDelaysUs.begin(), g_voDelaysUs.end());
    auto pct = [](double q) {
        return g_voDelaysUs.empty() ? 0.0
                                    : g_voDelaysUs[std::min<std::size_t>(
                                          g_voDelaysUs.size() - 1,
                                          static_cast<std::size_t>(q * g_voDelaysUs.size()))];
    };
    std::cout << "pedca=" << pedca << " seed=" << seed << " DS-CTS=" << g_dsCts
              << " RTS(P-EDCA STAs)=" << g_rtsPedca << " RTS(others)=" << g_rtsOther
              << " VO tx=" << g_voTx << " rx=" << g_voRx << " BE rx=" << g_beRx
              << " VO delay us p50=" << pct(0.5) << " p99=" << pct(0.99)
              << " p99.9=" << pct(0.999) << " max=" << pct(1.0) << std::endl;
    std::cout << "RTS by P-EDCA STA inside window=" << g_rtsInWindow
              << " CTS to P-EDCA STAs=" << g_ctsToPedca
              << " non-P-EDCA TX inside window=" << g_legacyInWindow
              << " DS-CTS inside another window=" << g_dsCtsInWindow << std::endl;
    for (const auto& [c, n] : g_cls)
    {
        std::cout << "  " << n << "  " << c << std::endl;
    }
    std::cout << "RTS start offset from DS-CTS end (us): ";
    for (const auto& [off, n] : g_rtsOffsetUs)
    {
        std::cout << off << ":" << n << " ";
    }
    std::cout << std::endl;
    Simulator::Destroy();
    return 0;
}
