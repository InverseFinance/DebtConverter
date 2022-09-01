increasePerYear=30000000000000000;
owner=0x9D5Df30F475CEA915b1ed4C0CCa59255C897b61B;
treasury=0x9D5Df30F475CEA915b1ed4C0CCa59255C897b61B;
gov=0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
oracle=0xE8929AFd47064EfD36A7fB51dA3F8C5eb40c4cb4;
forge create --rpc-url $1 \
    --constructor-args $increasePerYear $owner $treasury $gov $oracle \
    --private-key $3 src/DebtConverter.sol:DebtConverter \
    --etherscan-api-key $2 \
    --verify

