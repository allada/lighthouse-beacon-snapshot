# Ethereum Archive Node Snapshot Tools
This repository holds the tools and commands that can be used to quickly deploy your own ETH Lighthouse node by downloading pre-built snapshots and installing them on an instance.

Similar projects:
* [Binance Smart Chain Archive Snapshot](https://github.com/allada/bsc-archive-snapshot)
* [Ethereum Archive Snapshot](https://github.com/allada/eth-archive-snapshot)

This project does come at a high personal cost. I do not represent a company and AWS
costs to maintain this these projects has averaged about $700USD/mo that comes out of my pocket directly.

Please consider donating especially if you are using this project to make money. I am considering changing
the license from Apache (extremely permissive) to something that requires a license (ie: fee) if you derive
money from it. I would like to avoid this at all costs though!

You can support me in this kind of public work by donating to:
`0xd6A6Da9F5622FcB3C9745a4DDA5DcCa75d92a1F0`
Prefer binance smart chain or ethereum, stable coins, eth, btc, or bnb.

Thank you!

# Lighthouse Beacon Snapshot
All Lighthouse beacon snapshots are hosted on S3 on the following path:
| s3://public-blockchain-snapshots/lighthouse/mainnet/beacon/

This path is public, but is configured as requester-pays. This means you'll need an AWS account in order access/download them. You may greatly reduce this cost to nearly zero by using AWS in us-west-2 region. In such case, you should only need to pay for the cost of the api request (ie: <$0.10USD).

# Download and build a lighthouse beacon node
As reference code I have provided: `build_lighthouse_beacon_node.sh` in this repo.

To build a server capable of running an archive node (this assumes ubuntu 22.04):
* Get an AWS account and ensure it is configured on the computer (I strongly encourage you to run this in AWS's EC2 on `im4gn.2xlarge` or larger/similar in `us-west-2`)
* Checkout this repo to the computer
* Run `sudo ./build_lighthouse_beacon_node.sh`.
* When it is done, it should be serving a lighthouse beacon node.

Note: It is recommended that you verify the block chain state for safety/security. You will likely need an [erigon](https://github.com/ledgerwatch/erigon) or [geth](https://github.com/ethereum/go-ethereum) node to also be running and configured. You can see an example of this in the [Ethereum Archive Snapshot](https://github.com/allada/eth-archive-snapshot/blob/master/build_archive_node.sh) repository.

# License
This repository is licensed under [Apache-2.0 license](https://github.com/allada/lighthouse-beacon-snapshot/blob/master/LICENSE.txt)
