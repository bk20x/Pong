import lib/netty
import raylib, raygui
import threading/channels
import std/[json, strutils, strformat]
from std/os  import sleep
from std/times import epochTime
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
    mkConnected,
    mkConnectAccept,
    mkDisconnect,
    mkQuit,
    mkReady,
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
  
proc drawTextCentered (text: string; screenW, screenH, scale: float32; y=screenH/2; color=Black) =
  let 
    maxSize  = screenW-40*scale
    scaledSize  = int32 min(32 * scale, (maxSize / text.len.float32) * 1.5)
    textLen  = measureText(text, scaledSize)
  drawText(text, int32(screenW/2 - textLen/2), y.int32, scaledSize, color)

template js (m: Msg): string =
  $(%*m)

var 
  isHost:    bool
  netThread: Thread[(string, int)]
  msgs:      Chan[Msg] = newChan[Msg]() # messages sent from the main thread (game thread) to the server or client
  replies:   Chan[Msg] = newChan[Msg]() # replies to the main thread from the server or client
  gameState: GameState = gsMenuMain

type NetworkState = enum 
  nsHandshake, 
  nsConnected, 
  nsConnectedInGame,
  nsNotifyDisconnect

proc serverProc(ipnPort: (string, int)) =
  var 
    server: Reactor
    message: Msg
    state = nsHandshake
  
  try:
    server = newReactor(ipnPort[0], ipnPort[1])
    echo fmt"Server started on {ipnPort[0]}:{ipnPort[1]}" 
  except CatchableError as e:
    echo fmt"Error starting server: {e.msg}"
    replies.send Msg(kind: mkError, err: e.msg)
    return

  while true:
    server.tick()     
    # recv from main
    if msgs.tryRecv(message):
      if message.kind == mkQuit:
        echo "Server sending mkQuit to clients"
        for conn in server.connections:
          server.send(conn, js Msg(kind: mkQuit))
        for _ in 0..100: server.tick() # flush it. this is janky lol but it works!
        echo "Exiting Server thread"
        server.socket.close()
        replies.send Msg(kind: mkQuit)
        return
      elif message.kind == mkUpdate:
        # send game stat to client
        for conn in server.connections:
          server.send(conn, js message)

    # talk to client
    for msg in server.messages:
      let m = parseJson(msg.data).to(Msg)
      if state == nsHandshake and m.kind == mkConnect:
        echo "Client sent mkConnect; sending mkConnectAccept"
        server.send(msg.conn, js Msg(kind: mkConnectAccept))
        replies.send Msg(kind: mkConnected)
        state = nsConnected
      elif state == nsConnected and m.kind == mkUpdate:
        replies.send m
      elif m.kind == mkDisconnect:
        echo "Client Disconnected, Exiting server thread"
        server.socket.close()
        replies.send Msg(kind: mkQuit)
        return

proc startServerThread(ip: string; port: int) = 
  createThread(netThread, serverProc, (ip, port))
    

proc clientProc(ipnPort: (string, int)) =
  var 
    client = newReactor()
    conn = client.connect(ipnPort[0], ipnPort[1])
    message: Msg 
    state = nsHandshake
    lastSent = 0.0
  defer:
    client.disconnect(conn)
    client.socket.close()

  while true:
    client.tick()
    # recv from main 
    if msgs.tryRecv(message): 
      if message.kind == mkQuit:
        echo "Client sending mkDisconnect"
        client.send(conn, js Msg(kind: mkDisconnect))
        for _ in 0..100: client.tick()
        echo "Exiting Client Thread"
        replies.send Msg(kind: mkQuit)
        return
      elif message.kind == mkUpdate:
        if state == nsConnected:
          client.send(conn, js message)

    # handshake
    if state == nsHandshake and epochTime() - lastSent > 1.0:
      echo "Client Sending Connect..."
      client.send(conn, js Msg(kind: mkConnect))
      lastSent = epochTime()
      sleep 10

    # talk to server
    for msg in client.messages:
      let m = parseJson(msg.data).to(Msg)
      case m.kind
      of mkConnectAccept:
        if state == nsHandshake:
          echo "Client Connected"
          state = nsConnected
          replies.send Msg(kind: mkConnected)
      of mkUpdate:
        replies.send m
      of mkQuit:
        echo "Server sent mkQuit. Exiting Client Thread."
        replies.send Msg(kind: mkQuit)
        return 
      else:
        discard

proc startClientThread(ip: string; port: int) =
  createThread(netThread, clientProc, (ip, port))


proc runGame: void

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
          errorMsg  = ""
          if netThread.running(): # if there was an error starting the server this should be false bc it returns immediately
            msgs.send Msg(kind: mkQuit) # only send quit if its running. otherwise if you press back and try to restart the server thread it will immediately be hit with mkQuit
            netThread.joinThread()
          gameState = gsMenuMain
        var msg: Msg
        let recvd = replies.tryRecv(msg)
        if recvd:
          case msg.kind
          of mkError:
            errorMsg = msg.err
          of mkConnected:
            gameState = if isHost: gsHostingConnected else: gsJoiningConnected
          else:
            discard
        if isHost:
          drawTextCentered("Waiting for someone to join...", screenW, screenH, scale, color = Black)
        else:
          drawTextCentered("Waiting for a response from peer...", screenW, screenH, scale, color = Black)
        if errorMsg != "":
          drawTextCentered(errorMsg, screenW, screenH, scale, y=screenH/2 - 60*scale, color = Black)
      else:
        discard # Loop breaks and `runGame` is called. it will naturally call THIS procedure again to restart (if the player wants to restart)
  if not windowShouldClose():
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
  var 
    msg: Msg
    running = true
    quitToMenu = true

  while running:
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
      let newX = clamp(player.pos.x + player.dir.float32 * delta * PlayerSpeed, 0, GameWidth - PlayerWidth)
      player.pos.x = newX

    if isHost:
      block updateBallX:
        let newX = ball.pos.x + ball.dir.x * delta * BallSpeed
        if newX - BallRadius/2 < 0 or (newX + BallRadius) > GameWidth:
          ball.dir.x = -ball.dir.x
        elif checkCollisionCircleRec(vec2(newX, ball.pos.y), BallRadius, player.rect):
          ball.dir.x = -ball.dir.x
        elif checkCollisionCircleRec(vec2(newX, ball.pos.y), BallRadius, rival.rect):
          ball.dir.x = -ball.dir.x
        else:
          ball.pos.x = newX

      block updateBallY:
        let newY = ball.pos.y + ball.dir.y * delta * BallSpeed
        if newY - BallRadius/2 < 0 or (newY + BallRadius) > GameHeight:
          ball.dir.y = -ball.dir.y
        elif checkCollisionCircleRec(vec2(ball.pos.x, newY), BallRadius, player.rect):
          if player.dir != 0: ball.dir.x = player.dir.float32
          ball.dir.y = -ball.dir.y
        elif checkCollisionCircleRec(vec2(ball.pos.x, newY), BallRadius, rival.rect):
          if rival.dir != 0: ball.dir.x = rival.dir.float32 
          ball.dir.y = -ball.dir.y
        else:
          ball.pos.y = newY
      
      msgs.send Msg(kind: mkUpdate, playerStat: player, ballStat: ball)
    else:
      msgs.send Msg(kind: mkUpdate, playerStat: player)
      

    while replies.tryRecv(msg):
      case msg.kind
      of mkQuit:
        running = false 
      of mkUpdate:
        if isHost:
          # mirror client 
          rival.pos.x = GameWidth - msg.playerStat.pos.x - PlayerWidth
          rival.pos.y = GameHeight - msg.playerStat.pos.y - PlayerHeight 
          # flip dir for collision 
          rival.dir = -msg.playerStat.dir
        else:
          # mirror host 
          rival.pos.x = GameWidth - msg.playerStat.pos.x - PlayerWidth
          rival.pos.y = GameHeight - msg.playerStat.pos.y - PlayerHeight
          rival.dir = -msg.playerStat.dir
          # mirror ball
          ball.pos.x = GameWidth - msg.ballStat.pos.x
          ball.pos.y = GameHeight - msg.ballStat.pos.y
      else: discard


    if windowShouldClose():
      quitToMenu = false
      msgs.send Msg(kind: mkQuit)
    
    if isKeyPressed Q:
      msgs.send Msg(kind: mkQuit)
    
    drawing:
      clearBackground Gray
      mode2D(camera):
        drawRectangle(0,0, GameWidth, GameHeight, LightGray)
        drawRectangle(player.rect, DarkBlue)
        drawRectangle(rival.rect,  DarkBlue)
        drawCircle(ball.pos, BallRadius, Maroon)
      drawText($getFPS(), 0, 0, (32 * scale).int32, Green)

  if netThread.running:
    netThread.joinThread()
  
  if quitToMenu:
    gameState = gsMenuMain
    hostOrJoinGame()



proc main = 
  setConfigFlags(flags WindowResizable)
  initWindow(600, 800, "Prison Pong!"); defer: closeWindow()
  setTargetFPS(60)
  hostOrJoinGame()


main()

