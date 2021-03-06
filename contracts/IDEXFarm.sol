// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.6.12;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

// import "@nomiclabs/buidler/console.sol";

interface IIDEXMigrator {
  // Perform LP token migration from legacy.
  // Take the current LP token address and return the new LP token address.
  // Migrator should have full access to the caller's LP token.
  // Return the new LP token address.
  //
  // XXX Migrator must have allowance access to original LP tokens and must
  // mint EXACTLY the same amount of new LP tokens.
  function migrate(IERC20 token, bool isToken1Quote, address WETH) external returns (IERC20);
}

contract IDEXFarm is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Info of each user.
  struct UserInfo {
    uint256 amount; // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    //
    // We do some fancy math here. Basically, any point in time, the amount of reward tokens
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accRewardPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
    //   1. The pool's `accRewardPerShare` (and `lastRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
  }

  // Info of each pool.
  struct PoolInfo {
    IERC20 lpToken; // Address of LP token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. Reward to distribute per block.
    uint256 lastRewardBlock; // Last block number that reward distribution occurs.
    uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12. See below.
  }

  // The reward token
  IERC20 public rewardToken;
  // Reward tokens created per block.
  uint256 public rewardTokenPerBlock;
  // The migrator contract. It has a lot of power. Can only be set through governance (owner).
  IIDEXMigrator public migrator;

  // Info of each pool.
  PoolInfo[] public poolInfo;
  // Info of each user that stakes LP tokens.
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;
  // Total allocation points. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint = 0;

  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(
    address indexed user,
    uint256 indexed pid,
    uint256 amount
  );

  constructor(IERC20 _rewardToken, uint256 _rewardTokenPerBlock) public {
    rewardToken = _rewardToken;
    rewardTokenPerBlock = _rewardTokenPerBlock;
  }

  function poolLength() external view returns (uint256) {
    return poolInfo.length;
  }

  // Add a new lp to the pool. Can only be called by the owner.
  // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
  function add(
    uint256 _allocPoint,
    IERC20 _lpToken,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    poolInfo.push(
      PoolInfo({
        lpToken: _lpToken,
        allocPoint: _allocPoint,
        lastRewardBlock: block.number,
        accRewardPerShare: 0
      })
    );
  }

  // Update the given pool's reward allocation point. Can only be called by the owner.
  function set(
    uint256 _pid,
    uint256 _allocPoint,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
      _allocPoint
    );
    poolInfo[_pid].allocPoint = _allocPoint;
  }

  // Set the migrator contract. Can only be called by the owner.
  function setMigrator(IIDEXMigrator _migrator) public onlyOwner {
    require(address(migrator) == address(0), 'setMigrator: already set');
    migrator = _migrator;
  }

  // Migrate lp token to another lp contract. We trust that migrator contract is good.
  function migrate(uint256 _pid, bool isToken1Quote, address WETH) public onlyOwner {
    require(address(migrator) != address(0), 'migrate: no migrator');
    PoolInfo storage pool = poolInfo[_pid];
    IERC20 lpToken = pool.lpToken;
    uint256 bal = lpToken.balanceOf(address(this));
    lpToken.safeApprove(address(migrator), bal);
    IERC20 newLpToken = migrator.migrate(lpToken, isToken1Quote, WETH);
    require(bal == newLpToken.balanceOf(address(this)), 'migrate: bad');
    pool.lpToken = newLpToken;
  }

  // Return reward multiplier over the given _from to _to block.
  function getMultiplier(uint256 _from, uint256 _to)
    public
    pure
    returns (uint256)
  {
    return _to.sub(_from);
  }

  // View function to see pending rewards on frontend.
  function pendingReward(uint256 _pid, address _user)
    external
    view
    returns (uint256)
  {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_user];
    uint256 accRewardPerShare = pool.accRewardPerShare;
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (block.number > pool.lastRewardBlock && lpSupply != 0) {
      uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
      uint256 rewardQuantity =
        multiplier.mul(rewardTokenPerBlock).mul(pool.allocPoint).div(
          totalAllocPoint
        );
      accRewardPerShare = accRewardPerShare.add(
        rewardQuantity.mul(1e12).div(lpSupply)
      );
    }
    return user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
  }

  // Update reward variables for all pools. Be careful of gas spending!
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 pid = 0; pid < length; ++pid) {
      updatePool(pid);
    }
  }

  // Update reward variables of the given pool to be up-to-date.
  function updatePool(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    if (block.number <= pool.lastRewardBlock) {
      return;
    }
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (lpSupply == 0) {
      pool.lastRewardBlock = block.number;
      return;
    }
    uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
    uint256 rewardQuantity =
      multiplier.mul(rewardTokenPerBlock).mul(pool.allocPoint).div(
        totalAllocPoint
      );
    pool.accRewardPerShare = pool.accRewardPerShare.add(
      rewardQuantity.mul(1e12).div(lpSupply)
    );
    pool.lastRewardBlock = block.number;
  }

  // Deposit LP tokens to Farm for reward allocation.
  function deposit(uint256 _pid, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    updatePool(_pid);
    if (user.amount > 0) {
      uint256 pending =
        user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
      if (pending > 0) {
        safeRewardTokenTransfer(msg.sender, pending);
      }
    }
    if (_amount > 0) {
      pool.lpToken.safeTransferFrom(
        address(msg.sender),
        address(this),
        _amount
      );
      user.amount = user.amount.add(_amount);
    }
    user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
    emit Deposit(msg.sender, _pid, _amount);
  }

  // Withdraw LP tokens from Farm.
  function withdraw(uint256 _pid, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    require(user.amount >= _amount, 'withdraw: not good');
    updatePool(_pid);
    uint256 pending =
      user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
    if (pending > 0) {
      safeRewardTokenTransfer(msg.sender, pending);
    }
    if (_amount > 0) {
      user.amount = user.amount.sub(_amount);
      pool.lpToken.safeTransfer(address(msg.sender), _amount);
    }
    user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
    emit Withdraw(msg.sender, _pid, _amount);
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  function emergencyWithdraw(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    pool.lpToken.safeTransfer(address(msg.sender), user.amount);
    emit EmergencyWithdraw(msg.sender, _pid, user.amount);
    user.amount = 0;
    user.rewardDebt = 0;
  }

  // Safe token transfer function, just in case pool does not have enough rewards.
  function safeRewardTokenTransfer(address _to, uint256 _amount) private {
    uint256 rewardBalance = rewardToken.balanceOf(address(this));
    require(rewardBalance >= _amount, 'safeRewardTokenTransfer: insufficient balance');

    rewardToken.transfer(_to, _amount);
  }

  // Admin controls //

  // Assert _withUpdate or new emission rate will be retroactive to last update for all pools
  function setRewardPerBlock(uint256 _rewardTokenPerBlock, bool _withUpdate)
    external
    onlyOwner
  {
    if (_withUpdate) {
      massUpdatePools();
    }
    rewardTokenPerBlock = _rewardTokenPerBlock;
  }

  function withdrawRewardToken(uint256 _amount) external onlyOwner {
    rewardToken.transfer(msg.sender, _amount);
  }
}
