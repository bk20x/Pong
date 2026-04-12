import netty
import raylib, raygui
import threading/channels
import std/[json, strutils]
from std/os  import sleep
from std/net import parseIpAddress, close
type
  Player = object
    pos:   Vector2
    dir:   int
    goals: int

  Ball = object
    pos: Vector2
    dir: Vector2
    
  MsgKind = enum 
    mkError,
    mkConnect,
    mkDisconnect,
    mkQuit,
    mkUpdate

  Msg = object
    case kind: MsgKind
    of mkError:
      err: string
    of mkUpdate:
      playerStat: Player
      ballStat:   Ball
    else:
      discard

  GameState = enum 
    gsMenuMain,          
    gsMenuHosting,       # Chose `Host Game` in gsMenuMain
    gsHostingWaiting,    # Entered ip and port
    gsHostingConnected,  # In game... same for Join
    gsMenuJoining,
    gsJoiningWaiting, 
    gsJoiningConnected

const
  GameWidth       = 600
  GameHeight      = 600
  MaxLives        = 3
  PlayerSpeed     = 200
  PlayerWidth     = 128
  PlayerHeight    = 10
  PlayerElevation = 20
  BallRadius      = 8
  BallSpeed       = 200

func vec2 (x=0f, y=0f): auto = 
  Vector2(x: x, y: y)
func rect (x=0f, y=0f, width=0f, height=0f): auto = 
  Rectangle(x: x, y: y, width: width, height: height)
func rect (player: Player): auto = 
  rect(player.pos.x, player.pos.y, PlayerWidth, PlayerHeight)


var 
  isHost:    bool
  netThread: Thread[(string, int)]
  msgs:      Chan[Msg] = newChan[Msg]()
  replies:   Chan[Msg] = newChan[Msg]()
  gameState: GameState = gsMenuMain

proc serverProc (ipnPort: (string, int)) =
  try:
    var 
      server = newReactor(ipnPort[0], ipnPort[1])
      message: Msg
    while true:
      server.tick()
      for con in server.newConnections:
        echo "Connection from: ", con.address
      if msgs.tryRecv(message):
        if message.kind == mkQuit:
          echo "Exiting Server Thread"
          server.socket.close()
          break
          

  except CatchableError as e:
    replies.send Msg(kind: mkError, err: e.msg)


proc startServerThread(ip: string; port: int) = 
  createThread(netThread, serverProc, (ip, port))
    
proc clientProc (ipnPort: (string, int)) =
  var 
    client = newReactor()
    conn = client.connect(ipnPort[0], ipnPort[1])
    message: Msg
  while true:
    client.tick()
    if msgs.tryRecv(message):
      if message.kind == mkQuit:
        echo "Exiting Client Thread"
        client.disconnect(conn)
        client.socket.close()
        break
  
proc startClientThread(ip: string; port: int) =
  createThread(netThread, clientProc, (ip, port))

proc drawTextCentered (text: string; screenW, screenH, scale: float32; y=screenH/2; color=Black) =
  let 
    maxSize  = screenW-40*scale
    scaledSize  = int32 min(32 * scale, (maxSize / text.len.float32) * 1.5)
    textLen  = measureText(text, scaledSize)
  drawText(text, int32(screenW/2 - textLen/2), y.int32, scaledSize, color)

proc runGame (): void

proc hostOrJoinGame =
  var 
    ip        = newStringOfCap(15) # ipv4 lengths. no ipv6 (no one is typing that shit)
    port      = newStringOfCap(5)
    choseIp   = false
    chosePort = false
    errorMsg  = ""
  while gameState notin {gsHostingConnected, gsJoiningConnected} and not windowShouldClose():
    let
      screenW = getRenderWidth().float32
      screenH = getRenderHeight().float32
      scale   = min(screenW / GameWidth, screenH / GameHeight)

    proc tryHostOrJoin =
      var portNo: int
      let 
        inputWidth  = 192*scale      
        inputHeight = inputWidth/4
        fontSize    = int32(64*scale)
      if button(rect(screenW / 2 - inputWidth/2 - inputWidth/8, screenH/2 - inputWidth/4, inputWidth/8, inputWidth/8), "<"):
        if choseIp: 
          choseIp = false 
        else: 
          gameState = gsMenuMain
        return       
      if not choseIp:
        drawText("IP:", int32(screenW/2 - inputWidth/4), int32(screenH/2 - inputWidth/2 - 32), fontSize, Black)
        if errorMsg.len != 0:
          drawTextCentered(errorMsg, screenW, screenH, scale, y = (screenH/2 + inputHeight + 20*scale))
        if textBox(rect(screenW/2 - inputWidth/2, screenH/2 - inputWidth/4, inputWidth, inputHeight), ip, true):
          try:
            discard parseIpAddress(ip)
            errorMsg = ""
          except CatchableError as e:
            errorMsg = e.msg
            return
          if isKeyPressed(Enter) and errorMsg.len == 0: choseIp = true
      else:
        if errorMsg.len != 0:
          drawTextCentered(errorMsg, screenW, screenH, scale, y = (screenH/2 + inputHeight + 20*scale))
        drawText("Port:", int32(screenW/2 - inputWidth/4), int32(screenH/2 - inputWidth/2 - 32), fontSize, Black)
        if textBox(rect(screenW/2 - inputWidth/2, screenH/2 - inputWidth/4, inputWidth, inputHeight), port, true):
          if port.len > 0:
            try:
              portNo = parseInt(port)
              if portNo notin 0..int(uint16.high):
                errorMsg = "Port must be in range 0..65535"
              else:
                errorMsg = ""
            except CatchableError as e:
              errorMsg = e.msg
          else:
            errorMsg = "Must Provide a Port Number"
          if isKeyPressed(Enter) and errorMsg.len == 0: chosePort = true

      if choseIp and chosePort:
        case gameState
        of gsMenuHosting:
          startServerThread(ip, portNo)
          gameState = gsHostingWaiting
        of gsMenuJoining:
          startClientThread(ip, portNo)
          gameState = gsJoiningWaiting
        else:
          discard
    ##################################################
    drawing:
      Default.guiSetStyle(TextSize, int32(20*scale))
      clearBackground Gray
      let
        buttonW = 136*scale 
        buttonH = buttonW/2
      case gameState
      of gsMenuMain:
        if button(rect(screenW/2 - buttonW, screenH/2 - buttonH, buttonW, buttonH), "Host Game"):
          gameState = gsMenuHosting
        elif button(rect(screenW/2, screenH/2 - buttonH, buttonW, buttonH), "Join Game"):
          gameState = gsMenuJoining
      of gsMenuHosting, gsMenuJoining: 
        isHost = gameState == gsMenuHosting
        tryHostOrJoin()
      of gsHostingWaiting, gsJoiningWaiting:
        if button(rect(0, 0, buttonW/2, buttonW/4), "< Back"):
          choseIp   = false
          chosePort = false
          msgs.send Msg(kind: mkQuit)
          netThread.joinThread()
          gameState = gsMenuMain
        var msg: Msg
        let recvd = replies.tryRecv(msg)
        if recvd:
          case msg.kind
          of mkError:
            errorMsg = msg.err
          else:
            assert(false, "Todo")
        if gameState == gsHostingWaiting:
          drawTextCentered("Waiting for someone to join...", screenW, screenH, scale, color = Black)
        else:
          drawTextCentered("Waiting for a response from peer...", screenW, screenH, scale, color = Black)
        if errorMsg != "":
          drawTextCentered(errorMsg, screenW, screenH, scale, y=screenH/2 - 60*scale, color = Black)
      else:
        discard # Loop breaks and `runGame` is called. it will naturally call THIS procedure again to restart (if the player wants to restart)
  runGame()
    

      
proc runGame = 
  var
    camera = Camera2D(zoom: 1f)
    player = Player(
      pos: vec2(GameWidth/2 - PlayerWidth/2, GameHeight - (PlayerElevation + PlayerHeight)),
    )
    rival  = Player(
      pos: vec2(GameWidth/2 - PlayerWidth/2, 0 + (PlayerElevation + PlayerHeight))
    )
    ball = Ball(
      pos: if isHost: 
             vec2(player.pos.x + PlayerWidth/2, player.pos.y - PlayerHeight) 
           else: 
             vec2(rival.pos.x + PlayerWidth/2, rival.pos.y + PlayerHeight*2),
      dir: vec2(0, 1)
    )
  var goToMenu = false
  while not windowShouldClose():
    let 
      delta   = getFrameTime()
      screenW = getRenderWidth().float32
      screenH = getRenderHeight().float32
      scale   = min(screenW / GameWidth, screenH / GameHeight)
    camera.zoom   = scale
    camera.offset = vec2(
      x = (screenW - (GameWidth  * scale)) * 0.5f,
      y = (screenH - (GameHeight * scale)) * 0.5f
    )
    block updatePlayer:
      player.dir = 0
      if isKeyDown(A) or isKeyDown(Left):
        player.dir -= 1
      elif isKeyDown(D) or isKeyDown(Right):
        player.dir += 1
      let newX = clamp(player.pos.x + player.dir.float32*delta*PlayerSpeed, 0, GameWidth - PlayerWidth)
      player.pos.x = newX

    block updateBallX:
      if isHost:
        let newX = ball.pos.x + ball.dir.x*delta*BallSpeed
        if newX - BallRadius/2 < 0 or (newX + BallRadius) > GameWidth:
          ball.dir.x = -ball.dir.x
          break updateBallX
        elif checkCollisionCircleRec(vec2(newX, ball.pos.y), BallRadius, player.rect):
          ball.dir.x = -ball.dir.x
          break updateBallX
        elif checkCollisionCircleRec(vec2(newX, ball.pos.y), BallRadius, rival.rect):
          ball.dir.x = -ball.dir.x
          break updateBallX
        ball.pos.x = newX

    block updateBallY:
      if isHost:
        let newY = ball.pos.y + ball.dir.y*delta*BallSpeed
        if newY - BallRadius/2 < 0 or (newY + BallRadius) > GameHeight:
          ball.dir.y = -ball.dir.y
          break updateBallY
        elif checkCollisionCircleRec(vec2(ball.pos.x, newY), BallRadius, player.rect):
          if player.dir != 0: ball.dir.x = player.dir.float32
          ball.dir.y = -ball.dir.y
          break updateBallY 
        elif checkCollisionCircleRec(vec2(ball.pos.x, newY), BallRadius, rival.rect):
          if player.dir != 0: ball.dir.x = rival.dir.float32
          ball.dir.y = -ball.dir.y
          break updateBallY 
        ball.pos.y = newY
    if isKeyPressed F:
      goToMenu  = true
      gameState = gsMenuMain
      break
    drawing:
      clearBackground Gray
      mode2D(camera):
        drawRectangle(0,0, GameWidth, GameHeight, LightGray)
        drawRectangle(player.rect, DarkBlue)
        drawRectangle(rival.rect,  DarkBlue)
        drawCircle(ball.pos, BallRadius, Maroon)
      drawText($getFPS(), 0, 0, 32*scale.int32, Green)
  if goToMenu:
    msgs.send Msg(kind: mkQuit)
    hostOrJoinGame()

proc main = 
  setConfigFlags(flags WindowResizable)
  initWindow(600, 800, "Prison Pong!"); defer: closeWindow()
  setTargetFPS(60)
  hostOrJoinGame()
  if netThread.running:
    netThread.joinThread()


main()

