module.exports = {
  content: ["./ui_kit/src/**/*.rs"],
  theme: {
    extend: {
      colors: {
        primary: {
          DEFAULT: "#4d4dff",
          light: "#5252f7",
          dark: "#4343fa",
        },
        secondary: {
          DEFAULT: "#3a3a3a",
          light: "#39383b",
          dark: "#29292b",
        },
        background: {
          DEFAULT: "#040405",
          light: "#16161c",
          dark: "#000000",
        },
        foreground: {
          DEFAULT: "#2c2c2c",
          light: "#393939",
          dark: "#2c2c2c",
        },
        success: {
          DEFAULT: "#1dd1a1",
          light: "#00c29c",
        },
        warning: {
          DEFAULT: "#f5af19",
          light: "#feca57",
        },
        danger: {
          DEFAULT: "#f93854",
          light: "#fa4662;",
        },
        muted: "#6b6b87",
        dark: "#acacbf",
        bright: "#dfdff7",
      },
      fontFamily: {
        poppins: ["Poppins"],
        space: ["Space Mono"],
      },
    },
  },
  variants: {},
  plugins: [],
}
