#include "ns3/core-module.h"
#include "ns3/network-module.h"
#include "ns3/internet-module.h"
#include "ns3/point-to-point-module.h"
#include "ns3/applications-module.h"

using namespace ns3;
NS_LOG_COMPONENT_DEFINE("TwoNodes");

int main()
{
    // 1. Create two nodes
    NodeContainer nodes;
    nodes.Create(2);
    NS_LOG_UNCOND("Created two nodes");

    // 2. Create a point-to-point link
    PointToPointHelper pointToPoint;
    pointToPoint.SetDeviceAttribute("DataRate", StringValue("5Mbps"));
    pointToPoint.SetChannelAttribute("Delay", StringValue("2ms"));

    NetDeviceContainer devices;
    devices = pointToPoint.Install(nodes);
    NS_LOG_UNCOND("Connected Node 0 and Node 1");

    // 3. Install Internet protocol stack
    InternetStackHelper stack;
    stack.Install(nodes);

    // 4. Give the nodes IP addresses
    Ipv4AddressHelper address;
    address.SetBase("10.1.1.0", "255.255.255.0");

    Ipv4InterfaceContainer interfaces;
    interfaces = address.Assign(devices);
    NS_LOG_UNCOND("Node 0 IP: " << interfaces.GetAddress(0));
    NS_LOG_UNCOND("Node 1 IP: " << interfaces.GetAddress(1));

    // 5. Create a UDP receiver on Node 1
    uint16_t port = 9;

    UdpEchoServerHelper server(port);
    ApplicationContainer serverApp = server.Install(nodes.Get(1));

    serverApp.Start(Seconds(1.0));
    serverApp.Stop(Seconds(10.0));

    // 6. Create a UDP sender on Node 0
    UdpEchoClientHelper client(interfaces.GetAddress(1), port);

    client.SetAttribute("MaxPackets", UintegerValue(5));
    client.SetAttribute("Interval", TimeValue(Seconds(1.0)));
    client.SetAttribute("PacketSize", UintegerValue(1024));

    ApplicationContainer clientApp = client.Install(nodes.Get(0));

    clientApp.Start(Seconds(2.0));
    clientApp.Stop(Seconds(10.0));
    
    
    // 7. Run simulation
    NS_LOG_UNCOND("Starting simulation...");
    Simulator::Run();
    Simulator::Destroy();
    return 0;
}
